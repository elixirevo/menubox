import AppKit
import Combine
import Darwin

enum PermissionAccess: Equatable {
    case available, denied, unavailable

    var title: String {
        switch self {
        case .available: return "Ready"
        case .denied: return "Access needed"
        case .unavailable: return "Unable to check"
        }
    }
}

struct PermissionSnapshot: Equatable {
    enum Kind: Hashable { case accessibility, fullDiskAccess }

    let accessibility: Bool
    // nil means this OS does not use the Full Disk Access backend.
    let fullDiskAccess: PermissionAccess?

    var needsAttention: Set<Kind> {
        var result = Set<Kind>()
        if !accessibility { result.insert(.accessibility) }
        if let fullDiskAccess, fullDiskAccess != .available { result.insert(.fullDiskAccess) }
        return result
    }

    var isReady: Bool { needsAttention.isEmpty }

    static func read(macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                     accessibility: () -> Bool = { ClickForwarder.accessibilityTrusted },
                     diskAccess: () -> PermissionAccess = { FullDiskAccessProbe.read() }) -> Self {
        .init(accessibility: accessibility(), fullDiskAccess: macOSMajorVersion == 27 ? diskAccess() : nil)
    }
}

enum FullDiskAccessProbe {
    /// Check only the protected file this feature actually needs. Do not inspect
    /// TCC.db or unrelated user data, or use cached UserDefaults as proof of access.
    static func read(file: URL = NativeMenuBarPreferences.file) -> PermissionAccess {
        do {
            _ = try Data(contentsOf: file, options: .uncached)
            return .available
        } catch {
            return classify(error as NSError)
        }
    }

    static func classify(_ error: NSError) -> PermissionAccess {
        if (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code)) ||
            (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError) {
            return .denied
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return classify(underlying)
        }
        // A missing file or a different OS failure is not evidence of denial.
        return .unavailable
    }
}

struct PermissionPromptPolicy {
    private var previous: PermissionSnapshot?

    mutating func shouldPresent(_ snapshot: PermissionSnapshot, hasSeenSetup: Bool) -> Bool {
        defer { previous = snapshot }
        guard let previous else { return !hasSeenSetup || !snapshot.isReady }
        // Closing setup is respected until another permission is lost or the app
        // is relaunched. Polling and returning from System Settings must not nag.
        return !snapshot.needsAttention.subtracting(previous.needsAttention).isEmpty
    }
}

final class PermissionStore: ObservableObject {
    @Published private(set) var snapshot: PermissionSnapshot
    var onNeedsSetup: (() -> Void)?
    var onAccessRestored: (() -> Void)?

    private let defaults: UserDefaults
    private let probe: () -> PermissionSnapshot
    private var policy = PermissionPromptPolicy()
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private static let setupKey = "MenuBox.HasShownPermissionSetup.v1"

    init(defaults: UserDefaults = .standard, probe: @escaping () -> PermissionSnapshot = { .read() }) {
        self.defaults = defaults
        self.probe = probe
        snapshot = probe()
    }

    deinit { stop() }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.5
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    func refresh() {
        let wasReady = snapshot.isReady
        let current = probe()
        if snapshot != current { snapshot = current }
        if policy.shouldPresent(current, hasSeenSetup: defaults.bool(forKey: Self.setupKey)) {
            defaults.set(true, forKey: Self.setupKey)
            onNeedsSetup?()
        }
        if !wasReady && current.isReady { onAccessRestored?() }
    }
}
