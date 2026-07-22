import AppKit
import Darwin
import Foundation

// MARK: - Singleton guard

private let bundleID = Bundle.main.bundleIdentifier ?? "com.emrikol.Untracked"
private let singletonLockURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(bundleID).singleton.lock")
private let singletonLockFD = Darwin.open(singletonLockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)

// Split deliberately: "another copy already holds the lock" is the normal,
// expected path and exits quietly, but a lock we could not even open is an
// operational fault. Collapsing both into exit(0) made a permissions problem
// look exactly like a duplicate launch — the app just vanished, silently.
guard singletonLockFD >= 0 else {
    NSLog("Untracked: couldn't open singleton lock at \(singletonLockURL.path)")
    exit(EXIT_FAILURE)
}

guard flock(singletonLockFD, LOCK_EX | LOCK_NB) == 0 else {
    guard errno == EWOULDBLOCK else {
        NSLog("Untracked: singleton lock failed: \(String(cString: strerror(errno)))")
        exit(EXIT_FAILURE)
    }
    exit(0) // another instance is running — the expected case
}

// Keep singletonLockFD open for process lifetime. flock ownership is released
// automatically by the kernel on normal exit or crash.

// MARK: - Entry point

private let app = NSApplication.shared
private let delegate = AppDelegate()

app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
app.delegate = delegate
app.run()
