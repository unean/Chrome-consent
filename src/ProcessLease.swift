import Foundation

final class ProcessLease {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    static func acquire(_ url: URL) -> ProcessLease? {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return ProcessLease(fd)
    }
    deinit { close(descriptor) }
}

enum ProtectionLocks {
    static let guardian = Product.logURL.deletingLastPathComponent().appendingPathComponent("guardian.lock")
    static let watchdog = Product.logURL.deletingLastPathComponent().appendingPathComponent("watchdog.lock")
    static var active: Bool {
        guard let first = ProcessLease.acquire(guardian), let second = ProcessLease.acquire(watchdog) else { return true }
        withExtendedLifetime((first, second)) {}
        return false
    }
}
