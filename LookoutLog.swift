import Foundation

// Diagnostic logging — off by default, enabled per-machine via:
//   defaults write cc.jorviksoftware.Lookout debugLogging -bool YES
//   defaults delete cc.jorviksoftware.Lookout debugLogging   # turn off
// When on, timestamped lines are appended to
//   ~/Library/Logs/Lookout/lookout.log
// and the run before the last rotation is kept in lookout.log.1.
//
// Never write to Console/stderr or /tmp. This mirrors the Jorvik logging convention: a
// symlink-safe append to a 0700 directory, gated behind a UserDefaults flag read on every
// call. Repository names and item titles can be private, so the log stays on this Mac, is
// private to this user, and is never written unless the user turns it on. The token is
// never logged.
private let lkLogDirectory: URL = FileManager.default
    .urls(for: .libraryDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Logs", isDirectory: true)
    .appendingPathComponent("Lookout", isDirectory: true)
private let lkLogPath = lkLogDirectory.appendingPathComponent("lookout.log").path
private let lkPreviousLogPath = lkLogDirectory.appendingPathComponent("lookout.log.1").path

private let lkLogQueue = DispatchQueue(label: "cc.jorviksoftware.Lookout.log")
private let lkLogFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

/// Rotate once the live log passes this many bytes, keeping one previous generation, so
/// the logs can never occupy more than twice this figure.
///
/// 4 MB by default, as in the rest of the estate. A check writes two or three lines, so
/// 4 MB holds weeks of checks at one a minute. A knob, for a long diagnostic session:
///
///     defaults write cc.jorviksoftware.Lookout debugLogMaxBytes -int 20971520
private var lkLogMaxBytes: Int {
    let stored = UserDefaults.standard.integer(forKey: "debugLogMaxBytes")
    return stored > 0 ? stored : 4 * 1024 * 1024
}

/// Takes its message as an autoclosure, so a disabled call builds no string.
func lkLog(_ msg: @autoclosure () -> String) {
    guard UserDefaults.standard.bool(forKey: "debugLogging") else { return }
    let line = "\(lkLogFmt.string(from: Date()))  \(msg())\n"
    let limit = lkLogMaxBytes
    lkLogQueue.async {
        lkAppend(line)
        // One process and one serial queue write this file, so the size read here is
        // the file just written to, and nothing can rotate it in between.
        var info = stat()
        guard stat(lkLogPath, &info) == 0, info.st_size >= limit else { return }
        unlink(lkPreviousLogPath)
        guard rename(lkLogPath, lkPreviousLogPath) == 0 else { return }
        lkAppend("\(lkLogFmt.string(from: Date()))  log rotated at \(info.st_size) bytes; the run before this is in lookout.log.1\n")
    }
}

/// Appends one line. Runs on `lkLogQueue` only.
private func lkAppend(_ line: String) {
    guard let data = line.data(using: .utf8) else { return }
    try? FileManager.default.createDirectory(at: lkLogDirectory, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    // O_NOFOLLOW + 0700 parent dir closes the symlink-attack vector.
    let fd = open(lkLogPath, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return }
    defer { close(fd) }
    data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
}
