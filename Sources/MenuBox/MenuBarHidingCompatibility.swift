import Foundation

enum MenuBarHidingCompatibility {
    static var supportsSpacer: Bool {
        supportsSpacer(macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    static func supportsSpacer(macOSMajorVersion: Int) -> Bool {
        macOSMajorVersion < 27
    }

    // Assessment-mode restrictions cannot preserve arbitrary right-side system
    // items such as Focus, and affect all displays. Never substitute them for
    // hiding a section, even when the framework reports successful activation.
    static let unavailableMessage = "Menu bar hiding is not supported safely on macOS 27 yet. MenuBox and system icons will stay visible. Box UI is still available."
}
