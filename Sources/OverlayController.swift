// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

// swiftlint:disable redundant_string_enum_value - persisted raw values, see below
/// Which visual nag to show when you're not tracking.
///
/// Raw values are persisted in `~/.untracked.json` as `alertStyle`, so they
/// are spelled out: renaming a case must not silently invalidate saved configs.
///
/// `explicit_enum_raw_value` and `redundant_string_enum_value` are mutually
/// exclusive here — the first wants these written out, the second wants them
/// omitted because they match the case names. Persistence wins: the redundancy
/// is the safety. Scoped to this one declaration so the default rule still
/// applies everywhere else.
internal enum AlertStyle: String {
    case border = "border" // pulsing rim around each screen
    case menuBar = "menuBar" // pulsing red strip over the menu bar area
    case both = "both"
}

// swiftlint:enable redundant_string_enum_value

private enum OverlayKind { case border, strip }

/// Appearance constants for the nag.
private enum Look {
    /// Floor for the menu-bar strip height, for screens that report no inset.
    static let minimumMenuBarHeight: CGFloat = 24
    /// The strip is translucent by design; this multiplies the *configured*
    /// alpha rather than replacing it, so #RRGGBBAA still means something.
    static let stripAlphaFactor: CGFloat = 0.65
    // swiftlint:disable no_magic_numbers - animation curve, see doc comment below
    /// One "lub-dub": opacity keyframes and their timings. Between beats the
    /// layer is fully static at 0, which is what keeps idle cost at nothing.
    ///
    /// These values *are* the curve — each number is a point on it — so naming
    /// them individually would describe nothing the curve doesn't already say.
    static let beatOpacities: [Double] = [0.0, 0.80, 0.25, 0.60, 0.0]
    static let beatKeyTimes: [Double] = [0.0, 0.18, 0.42, 0.68, 1.0]
    // swiftlint:enable no_magic_numbers
    static let beatDuration: CFTimeInterval = 0.7
    /// Generous, so macOS can coalesce the beat with other wake-ups.
    static let beatToleranceFraction = 0.4
}

/// A borderless, click-through window that paints only its rim (border) or a
/// top strip (menuBar). Because `ignoresMouseEvents` is true it never blocks a
/// click, and it covers no usable content.
private final class OverlayWindow: NSWindow {
    init(screen: NSScreen, kind: OverlayKind, thickness: CGFloat, color: NSColor) {
        let rect: NSRect
        switch kind {
        case .border:
            rect = screen.frame

        case .strip:
            // The top inset (frame.maxY - visibleFrame.maxY) IS the menu bar
            // height for this screen. No notch / menu-item math needed — if the
            // notch occludes the middle, the flanking red is signal enough.
            let menuBarHeight = max(Look.minimumMenuBarHeight, screen.frame.maxY - screen.visibleFrame.maxY)
            rect = NSRect(
                x: screen.frame.minX,
                y: screen.frame.maxY - menuBarHeight,
                width: screen.frame.width,
                height: menuBarHeight
            )
        }

        super.init(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        // .screenSaver floats above normal windows, the menu bar, and full-screen
        // spaces. The trade-off: it also draws over an open menu briefly. Lower to
        // .statusBar if you'd rather it not, at the cost of full-screen coverage.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: rect.size))
        // Supply the layer rather than setting wantsLayer and force-unwrapping
        // whatever AppKit attaches: this way the layer is ours and non-optional.
        let layer = CALayer()
        view.layer = layer
        view.wantsLayer = true
        switch kind {
        case .border:
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderColor = color.cgColor
            layer.borderWidth = thickness

        case .strip:
            // Multiply the configured alpha by the strip's design factor rather
            // than replacing it. README documents #RRGGBBAA and `.border` above
            // already honours it, so replacing made one color render differently
            // per style — visibly inconsistent under `.both`. Convert
            // to sRGB first: reading `.alphaComponent` on a catalog color (the
            // `.systemRed` fallback) can raise.
            let configuredAlpha = color.usingColorSpace(.sRGB)?.alphaComponent ?? 1
            layer.backgroundColor = color.withAlphaComponent(configuredAlpha * Look.stripAlphaFactor).cgColor
        }
        layer.opacity = 0 // resting state is invisible; beats animate it transiently
        contentView = view
    }

    deinit {
        // Deliberately empty: NSWindow owns its own teardown. OverlayController
        // releases these by close()ing them and dropping them from `windows` —
        // both halves are required, see the comment in teardown().
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// Owns the overlay windows and the pulse animation. Show/hide is idempotent.
/// `@MainActor` because every member touches AppKit; the compiler now rejects
/// any attempt to drive the overlay from a background queue.
@MainActor
internal final class OverlayController {
    private var isVisible = false
    private var windows: [OverlayWindow] = []
    private var beatTimer: Timer?

    private var tint = NSColor.systemRed
    private var tintKey = "red"

    // Tunable from ~/.untracked.json via configure(...).
    internal private(set) var style: AlertStyle = .menuBar
    private var thickness: CGFloat = 10
    private var beatPeriod: TimeInterval = 8.0 // seconds between heartbeats

    internal init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        // Only the observer can be released here: beatTimer is @MainActor and
        // deinit is nonisolated, so it cannot be touched. It doesn't need to be —
        // startBeating() makes the timer invalidate itself once self is gone.
        NotificationCenter.default.removeObserver(self)
    }

    /// Apply settings. Re-renders live if currently visible; otherwise forces the
    /// next show() to rebuild fresh with the new parameters.
    internal func configure(style: AlertStyle, beatPeriod: TimeInterval, thickness: CGFloat) {
        self.style = style
        self.beatPeriod = beatPeriod
        self.thickness = thickness
        if isVisible {
            rebuild()
        } else {
            tintKey = ""
        }
    }

    @objc
    private func screensChanged() {
        if isVisible {
            rebuild()
        }
    }

    private func kinds(for style: AlertStyle) -> [OverlayKind] {
        switch style {
        case .border:
            return [.border]

        case .menuBar:
            return [.strip]

        case .both:
            return [.border, .strip]
        }
    }

    private func rebuild() {
        teardown()
        for screen in NSScreen.screens {
            for kind in kinds(for: style) {
                let window = OverlayWindow(screen: screen, kind: kind, thickness: thickness, color: tint)
                window.orderFrontRegardless()
                windows.append(window)
            }
        }
        startBeating()
    }

    /// Drive the heartbeat from a timer rather than an infinite animation: each
    /// fire plays a short one-shot beat, and between beats the overlay is fully
    /// static (opacity 0) so nothing recomposites. One timer wake per ~3.2s
    /// (high tolerance) instead of continuous per-frame compositing.
    private func startBeating() {
        beatTimer?.invalidate()
        beat() // beat immediately on show
        // Self-invalidating: the run loop owns this timer, not us, so if the
        // controller goes away it would otherwise keep firing forever into a nil
        // weak self. deinit can't do the job — it's nonisolated and beatTimer is
        // @MainActor — so the timer retires itself instead, which removes the
        // failure mode rather than relying on a teardown path being called.
        let timer = Timer(timeInterval: beatPeriod, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.beat() }
        }
        // Generous tolerance lets macOS batch this wake-up with others, so the
        // CPU isn't woken on our schedule alone — near-zero energy between beats.
        timer.tolerance = beatPeriod * Look.beatToleranceFraction
        RunLoop.main.add(timer, forMode: .common)
        beatTimer = timer
    }

    /// One quick lub-dub, then back to invisible. Your eye catches the motion;
    /// it doesn't linger.
    private func beat() {
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        //               rest  lub   dip   dub   off
        anim.values = Look.beatOpacities
        // swiftlint:disable:next legacy_objc_type - CoreAnimation types keyTimes as [NSNumber]
        anim.keyTimes = Look.beatKeyTimes.map(NSNumber.init(value:))
        anim.duration = Look.beatDuration
        anim.isRemovedOnCompletion = true
        for window in windows {
            window.contentView?.layer?.add(anim, forKey: "beat")
        }
    }

    private func teardown() {
        beatTimer?.invalidate()
        beatTimer = nil
        for window in windows {
            // `close()`, not `orderOut()`. Both take the window off screen, but
            // NSApplication keeps its own registry of live windows that a window
            // joins the first time it is ordered on, and **only close() removes
            // it from that registry**. With orderOut alone, `windows.removeAll()`
            // drops our reference while AppKit still holds one, so the NSWindow /
            // NSView / CALayer graph does not deallocate — it lingers until the
            // *next* show() happens to flush it.
            //
            // That lag is not academic here: hide() at the work-hours boundary is
            // the last overlay call of the day, and the app then idles until the
            // next morning. Verified against a real NSApplication run loop —
            // with orderOut, NSApp.windows.count stayed at 1 and deinit never
            // fired across 33 s of idle; with close() it drops immediately.
            //
            // Safe because isReleasedWhenClosed is false (see init): ARC still
            // owns the reference, close() just makes AppKit release its copy.
            window.close()
        }
        windows.removeAll()
    }

    /// Show the overlay with a given tint. `key` distinguishes tints so switching
    /// colors (e.g. green → red) rebuilds, while re-showing the same tint is a no-op.
    internal func show(tint: NSColor, key: String) {
        if isVisible, tintKey == key {
            return
        }
        self.tint = tint
        tintKey = key
        isVisible = true
        rebuild()
    }

    internal func hide() {
        guard isVisible else {
            return
        }
        isVisible = false
        teardown()
    }
}
