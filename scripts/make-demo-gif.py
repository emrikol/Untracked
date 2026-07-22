#!/usr/bin/env python3
"""Render docs/demo.gif — the two nag styles, for the README.

Run from the repo root: ./scripts/make-demo-gif.py

Deliberately a mockup, not a screenshot: a real capture would publish whatever
happens to be on the author's desktop. Everything that describes the *app's*
behaviour is taken from Sources/OverlayController.swift rather than invented —
the heartbeat keyframes, its duration, the strip's alpha factor, and the colour
come straight from `Look` and the shipped config defaults.

The one honest liberty is pacing: the real beat period is 8 s, which would make
a loop that is 91% static. The README says the timing is compressed.
"""

from PIL import Image, ImageDraw, ImageFont

W, H = 900, 560
SCALE = 2  # supersample, then downscale — cheap antialiasing
MENUBAR_H = 26

# --- values mirrored from OverlayController.Look + shipped config defaults ---
BEAT_OPACITIES = [0.0, 0.80, 0.25, 0.60, 0.0]
BEAT_KEYTIMES = [0.0, 0.18, 0.42, 0.68, 1.0]
BEAT_DURATION = 0.7
STRIP_ALPHA_FACTOR = 0.65
NOT_TRACKING = (0xFF, 0x3B, 0x30)
TRACKING = (0x34, 0xC7, 0x59)

FPS = 20
LOOP_SECONDS = 2.6
BEAT_STARTS = [0.35, 1.65]  # two beats per loop, so the rhythm reads as a pulse


def beat_opacity(t):
    """Piecewise-linear interpolation over the app's own keyframes."""
    for start in BEAT_STARTS:
        local = t - start
        if 0 <= local <= BEAT_DURATION:
            frac = local / BEAT_DURATION
            for i in range(len(BEAT_KEYTIMES) - 1):
                k0, k1 = BEAT_KEYTIMES[i], BEAT_KEYTIMES[i + 1]
                if k0 <= frac <= k1:
                    span = k1 - k0
                    p = 0 if span == 0 else (frac - k0) / span
                    return BEAT_OPACITIES[i] + p * (BEAT_OPACITIES[i + 1] - BEAT_OPACITIES[i])
    return 0.0


def font(size, mono=False):
    path = "/System/Library/Fonts/SFNSMono.ttf" if mono else "/System/Library/Fonts/SFNS.ttf"
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default()


def wallpaper(w, h):
    """A calm vertical gradient — it must not compete with the red pulse."""
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    top, bottom = (30, 62, 92), (58, 110, 124)
    for y in range(h):
        p = y / max(1, h - 1)
        d.line(
            [(0, y), (w, y)],
            fill=tuple(int(top[i] + (bottom[i] - top[i]) * p) for i in range(3)),
        )
    return img


def rounded(d, box, r, fill, outline=None, width=1):
    d.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)


def draw_scene(tracking):
    """The static desktop: wallpaper, a window, and the menu bar."""
    w, h = W * SCALE, H * SCALE
    img = wallpaper(w, h)
    d = ImageDraw.Draw(img, "RGBA")
    s = SCALE

    # A generic app window, so the overlay has something to sit above and the
    # click-through claim is visually plausible.
    wx, wy, ww, wh = 150 * s, 130 * s, 600 * s, 330 * s
    d.rounded_rectangle([wx + 6 * s, wy + 8 * s, wx + ww + 6 * s, wy + wh + 8 * s],
                        radius=12 * s, fill=(0, 0, 0, 70))
    rounded(d, [wx, wy, wx + ww, wy + wh], 12 * s, (246, 246, 248, 255))
    rounded(d, [wx, wy, wx + ww, wy + 34 * s], 12 * s, (232, 232, 236, 255))
    d.rectangle([wx, wy + 24 * s, wx + ww, wy + 34 * s], fill=(232, 232, 236, 255))
    for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = wx + (18 + i * 18) * s
        d.ellipse([cx - 5 * s, wy + 12 * s, cx + 5 * s, wy + 22 * s], fill=c)
    d.text((wx + ww / 2, wy + 17 * s), "Work", font=font(13 * s), fill=(90, 90, 96), anchor="mm")

    body = font(12 * s)
    for i, line in enumerate(["Editing all afternoon.", "Timer still not running.", ""]):
        d.text((wx + 26 * s, wy + (58 + i * 26) * s), line, font=body, fill=(120, 120, 128))
    for i in range(6):  # filler text bars
        d.rounded_rectangle(
            [wx + 26 * s, wy + (136 + i * 22) * s, wx + (26 + [420, 500, 360, 470, 300, 410][i]) * s,
             wy + (148 + i * 22) * s],
            radius=5 * s, fill=(226, 226, 232, 255))

    # Menu bar
    d.rectangle([0, 0, w, MENUBAR_H * s], fill=(244, 245, 248, 232))
    mb = font(12 * s)
    d.text((14 * s, MENUBAR_H * s / 2), "", font=font(14 * s), fill=(40, 40, 46), anchor="lm")
    x = 34 * s
    for label, bold in [("Work", True), ("File", False), ("Edit", False), ("View", False)]:
        d.text((x, MENUBAR_H * s / 2), label, font=mb, fill=(40, 40, 46), anchor="lm")
        x += (int(d.textlength(label, font=mb)) + 18 * s)

    # Right side: Untracked's own status icon, tinted by state, plus a clock.
    icon_c = TRACKING if tracking else NOT_TRACKING
    ix = w - 120 * s
    d.text((ix, MENUBAR_H * s / 2), "♥", font=font(16 * s), fill=icon_c, anchor="mm")
    d.text((w - 20 * s, MENUBAR_H * s / 2), "4:12 PM", font=mb, fill=(40, 40, 46), anchor="rm")
    return img


BORDER_THICKNESS = 10  # borderThickness default, in points


def caption(img, text):
    """Name the style being shown, so the loop doubles as documentation."""
    s = SCALE
    d = ImageDraw.Draw(img, "RGBA")
    f = font(13 * s)
    tw = d.textlength(text, font=f)
    x, y = img.size[0] / 2 - tw / 2 - 14 * s, img.size[1] - 46 * s
    d.rounded_rectangle([x, y, x + tw + 28 * s, y + 30 * s], radius=15 * s, fill=(0, 0, 0, 130))
    d.text((img.size[0] / 2, y + 15 * s), text, font=f, fill=(255, 255, 255, 235), anchor="mm")
    return img


def render_scene(style, base):
    """One style's worth of frames.

    The two styles composite differently *in the app*, and that difference is
    preserved here rather than smoothed over: `.strip` multiplies the colour's
    alpha by stripAlphaFactor, so at peak it is a 52% wash; `.border` draws
    borderColor at full saturation. The border therefore reads as far more
    vivid, which is exactly how it looks on a real screen.
    """
    frames = []
    s = SCALE
    for i in range(int(LOOP_SECONDS * FPS)):
        opacity = beat_opacity(i / FPS)
        img = base.copy()
        if opacity > 0.001:
            layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
            ld = ImageDraw.Draw(layer)
            if style == "strip":
                a = int(opacity * STRIP_ALPHA_FACTOR * 255)
                ld.rectangle([0, 0, img.size[0], MENUBAR_H * s], fill=NOT_TRACKING + (a,))
            else:
                a = int(opacity * 255)  # borderColor carries no alpha factor
                ld.rectangle([0, 0, img.size[0] - 1, img.size[1] - 1],
                             outline=NOT_TRACKING + (a,), width=BORDER_THICKNESS * s)
            img = Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")
        label = "Menu Bar Strip  ·  default" if style == "strip" else "Screen Border"
        frames.append(caption(img.convert("RGBA"), label).convert("RGB")
                      .resize((W, H), Image.LANCZOS))
    return frames


def render():
    base = draw_scene(tracking=False)
    return render_scene("strip", base) + render_scene("border", base)


if __name__ == "__main__":
    frames = render()
    out = "docs/demo.gif"
    from PIL import Image as _I
    strip = _I.new("RGB", (frames[0].width, frames[0].height * len(frames)))
    for i, f in enumerate(frames):
        strip.paste(f, (0, i * frames[0].height))
    pal = strip.quantize(colors=200, method=_I.Quantize.MEDIANCUT)
    pframes = [f.quantize(palette=pal, dither=_I.Dither.NONE) for f in frames]
    pframes[0].save(out, save_all=True, append_images=pframes[1:],
                    duration=int(1000 / FPS), loop=0, optimize=True)
    print(f"wrote {out}: {len(frames)} frames, {LOOP_SECONDS}s loop")
