import Foundation

enum FullDiskAccessRequest {
    static let helperArgument = "--menubox-register-full-disk-access"

    enum Failure: Error, Equatable {
        case missingExecutable
        case timedOut
        case helperFailed(Int32)
    }

    /// Registration is best-effort and never establishes that permission was granted.
    /// Keep this out of the periodic permission probe: only a user request should run it.
    static func perform(
        access: PermissionAccess,
        register: () throws -> Void = { try registerUsingHelper() },
        openSettings: () -> Void
    ) {
        if access != .available {
            do { try register() }
            catch { NSLog("[MenuBox] Full Disk Access registration attempt failed: %@", String(describing: error)) }
        }
        openSettings()
    }

    /// Run on a background queue. The normal app's capability preflights can cache a
    /// denial that prevents a later request from creating a System Settings entry.
    /// A fresh process of the same app requests access before any capability probes.
    static func registerUsingHelper(
        executableURL: URL? = Bundle.main.executableURL,
        timeout: TimeInterval = 3
    ) throws {
        guard let executableURL else { throw Failure.missingExecutable }
        let helper = Process()
        helper.executableURL = executableURL
        helper.arguments = [helperArgument]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        helper.terminationHandler = { _ in finished.signal() }
        try helper.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            if helper.isRunning { helper.terminate() }
            throw Failure.timedOut
        }
        guard helper.terminationStatus == 0 else { throw Failure.helperFailed(helper.terminationStatus) }
    }

    static func runHelper() -> Int32 {
        do {
            try registerApplication()
            return 0
        } catch {
            // A denied request is the expected path to a disabled list entry.
            return FullDiskAccessProbe.classify(error as NSError) == .denied ? 0 : 1
        }
    }

    static func registerApplication() throws {
        // Directory access triggers registration on modern macOS. This is not a
        // permission-status API; discard the directory names and never read file contents.
        // Reference: https://github.com/inket/FullDiskAccess
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.stocks", isDirectory: true)
        _ = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }
}
