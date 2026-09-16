# Permission setup

Settings → Permissions provides the permission name, its purpose, current access status, a button for the matching System Settings page, and a Finder shortcut to the running app bundle. If macOS asks for a restart after a change, follow that prompt.

- Accessibility is needed to discover menu bar items and open menus from Box. On macOS 27 the page uses the new “Device Control and Data Access” name alongside “Accessibility.”
- Full Disk Access is shown only for the macOS 27 preferences backend. The explanation states both why MenuBox uses it and that this system permission grants broader access to other apps' data.
- Screen Recording is not required by the current app-icon/menu flow and is not added to setup.

## Presentation and recovery

The Permissions tab opens on the first launch with this setup flow, including existing installations upgrading to it. A saved setup flag prevents repeating that welcome for returning users with working access. Missing access still opens the tab on each launch.

During a session, access is checked every three seconds and whenever MenuBox becomes active. A newly missing permission opens the tab. Repeated checks of the same missing permission, partial grants, and returning from System Settings do not repeatedly steal focus. A user can close setup and return through Settings or by attempting a feature that needs access.

The tab is selected explicitly even if the existing Settings window was on General or Display. It remains open after grants so the user can see the resulting status. Pending native hide requests resume once both permissions work. Explicitly showing the icons cancels that pending request. The macOS 26 spacer behavior remains unchanged and never probes the protected settings file.

## Access checks

Accessibility uses `AXIsProcessTrusted`. Full Disk Access has no dependency here on a TCC database query: the check performs an uncached, read-only access to the Control Center preferences file already needed by the hiding backend. It does not read unrelated protected user data or write settings as a permission test.

“Ready” means this app can read that resource. A file access denial is reported as “Access needed.” A missing file or other read failure is reported separately as “Unable to check,” rather than asserting the user denied permission. Preference schema compatibility remains a separate backend concern.

The permission itself is enabled in macOS System Settings. Apple's [privacy settings guide](https://support.apple.com/guide/mac-help/mchl211c911f/mac) describes adding apps to Full Disk Access, and [Advances in macOS Security](https://developer.apple.com/videos/play/wwdc2019/701/) describes checking access to the needed resource and directing users to system privacy settings.

## Verification — 2026-09-16

- The installed `permission-setup-v1` build automatically opened Permissions with both entries marked “Access needed.” The full page fit in its default window and both buttons opened the correct macOS 27 settings panes.
- After refreshing the previously authorized app entries, Accessibility changed to “Ready,” then Full Disk Access changed to “Ready” and the page reported “All required permissions are ready.” These updates did not require the Check Again button.
- The pending hide operation completed after the grants. Following the system restart flow, MenuBox ran with its hidden section restored and no visible settings window in the recorded WindowServer snapshot.
- XCTest executed 88 tests: 87 passed, one opt-in live menu test skipped, zero failures. New coverage includes legacy OS behavior, initial setup, returning users, missing access on relaunch, no repeated prompts, revocation, partial grants, capability rechecks and distinguishing permission denial from other file errors. Revocation policy is covered by these automated tests; a separate live revoke/regrant cycle was not performed after setup completed.
- The arm64 release build and strict app signature verification passed. Evidence is under `artifacts/macos27/research/permission-setup/`; the installed bundle is `/Applications/MenuBox.app`.
