import AppKit
import ApplicationServices
import Darwin
import ObjectiveC

/// Read-only capability probe. A loaded framework is not evidence that the
/// process can read or change the system's per-app visibility preferences.
enum MenuBarAccessDiagnostics {
    private static let framework = dlopen(
        "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore",
        RTLD_LAZY | RTLD_LOCAL
    )

    static func writeSnapshot() {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else { return }
        var report: [String: Any] = [
            "schemaVersion": 1,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unbundled",
            "bundlePath": Bundle.main.bundleURL.path,
            "accessibilityTrusted": AXIsProcessTrusted(),
            "writesAttempted": false,
            "status": "unavailable"
        ]

        if let framework,
           let symbol = dlsym(framework, "$s17MenuBarClientCore30TrackedApplicationsPreferencesC6sharedACvgZ") {
            // This ABI is private and has only been inspected on macOS 27.
            // Do not call a setter or infer an empty store from an unreadable key.
            let accessor = unsafeBitCast(symbol, to: (@convention(thin) () -> AnyObject).self)
            let controller = accessor()
            if let base = Mirror(reflecting: controller).superclassMirror,
               let defaults = base.children.first(where: { $0.label == "userDefaults" })?.value as? UserDefaults,
               let keys = base.children.first(where: { $0.label == "keys" })?.value as? [ReferenceWritableKeyPath<UserDefaults, Any?>],
               let key = keys.first(where: { $0._kvcKeyPathString == "trackedApplications" }) {
                report["domain"] = "group.com.apple.controlcenter"
                report["key"] = "trackedApplications"
                if let value = defaults[keyPath: key] {
                    report["status"] = "readable"
                    report["valueType"] = String(describing: type(of: value))
                    if let data = value as? Data {
                        report["byteCount"] = data.count
                        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                           let array = plist as? [Any] {
                            report["serializedElementCount"] = array.count
                        }
                    }
                } else {
                    report["status"] = "unreadable"
                    report["reason"] = "The existing trackedApplications preference could not be read. No write was attempted."
                }
            } else {
                report["reason"] = "Unrecognized private controller layout."
            }
        } else {
            report["reason"] = "Private preferences controller is unavailable."
        }

        // The user explicitly enabled Full Disk Access for this verification.
        // Probe the actual container only when separately opted in. No fallback
        // reads or writes are made if normal filesystem access is denied.
        if UserDefaults.standard.bool(forKey: "MenuBoxEnableContainerAccessProbe") {
            let container = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/group.com.apple.controlcenter", isDirectory: true)
            let file = container.appendingPathComponent("Library/Preferences/group.com.apple.controlcenter.plist")
            do {
                let fileData = try Data(contentsOf: file)
                let plist = try PropertyListSerialization.propertyList(from: fileData, format: nil)
                let diskValue = (plist as? [String: Any])?["trackedApplications"] as? Data
                report["containerFileReadable"] = true
                report["containerTrackedDataPresent"] = diskValue != nil
                if let defaults = containerDefaults(container), let diskValue {
                    let apiValue = defaults.data(forKey: "trackedApplications")
                    report["explicitContainerReadable"] = apiValue != nil
                    report["explicitContainerMatchesFile"] = apiValue == diskValue
                    if let decoded = try PropertyListSerialization.propertyList(from: diskValue, format: nil) as? [Any] {
                        report["containerSerializedElementCount"] = decoded.count
                    }
                }
            } catch {
                report["containerFileReadable"] = false
                report["containerReadError"] = (error as NSError).code
                report["containerReadErrorDomain"] = (error as NSError).domain
            }
        }

        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let directory = support.appendingPathComponent("MenuBox/Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("menu-bar-access.json"), options: .atomic)
        } catch {
            NSLog("[MenuBox] Could not write menu bar access diagnostics: %@", String(describing: error))
        }
    }

    static func containerDefaults(_ container: URL) -> UserDefaults? {
        let allocateSelector = NSSelectorFromString("alloc")
        let initializeSelector = NSSelectorFromString("_initWithSuiteName:container:")
        guard let allocation = class_getClassMethod(UserDefaults.self, allocateSelector),
              let initialization = class_getInstanceMethod(UserDefaults.self, initializeSelector) else { return nil }
        // alloc and init return a single owned Objective-C reference. Keep the
        // allocation unmanaged until init can substitute the class-cluster object.
        typealias Allocate = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
        typealias Initialize = @convention(c) (UnsafeMutableRawPointer, Selector, NSString, NSURL) -> Unmanaged<AnyObject>?
        let allocate = unsafeBitCast(method_getImplementation(allocation), to: Allocate.self)
        let initialize = unsafeBitCast(method_getImplementation(initialization), to: Initialize.self)
        guard let object = allocate(UserDefaults.self, allocateSelector) else { return nil }
        return initialize(object, initializeSelector, "group.com.apple.controlcenter", container as NSURL)?
            .takeRetainedValue() as? UserDefaults
    }
}
