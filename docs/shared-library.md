# MacAppEssentials integration

MenuBox consumes the local `../tools/library` checkout of
[MacAppEssentials](https://github.com/elixirevo/mac-app-essentials). The integration
was developed against revision `c270e68e993a49854fa5638071a67967c58530f4`.
Keep the repository's `Integrations` directory beside its base package; the
Sparkle adapter references that same package by relative path.

## Ownership

- `MacAppSettings` provides the settings window, sidebar, forms, shortcut recorder,
  permission guidance, login item controls, updates and app information.
- `MacAppCore` resolves the shared system/English/Korean language preference.
  MenuBox supplies its own settings translations in its SwiftPM resource bundle.
  Language changes take effect after restarting; Box UI's existing operational
  messages are still English.
- `MacAppLifecycle` validates `LSUIElement=true`, keeps MenuBox running when its
  windows close and opens settings on Finder/Spotlight reopen. Settings never
  switches the app to regular/Dock mode.
- `MacAppMainMenu` supplies standard app/edit/window commands and Settings (`⌘,`).
- `MacAppUpdatesSparkle` owns the single updater and its shared settings model.
  The feed and signing key remain in MenuBox's Info.plist. Sparkle is pinned to
  the adapter's tested 2.10.0 dependency; startup failure leaves checking disabled.

The box and tape status items remain MenuBox-owned: their geometry, autosave
positions, replica recovery, variable spacer width and configurable clicks are
part of the hiding backend. `MacAppMenuBar` does not expose those controls, so
replacing them with its standard status item would lose existing behavior.

`SettingsStore` retains the existing `MenuBox.AppSettings.v3` schema and legacy
StatusBox migration. Shortcut conversion preserves physical key codes and modifier
flags. Recording suspends MenuBox hotkeys; duplicate or rejected registrations
leave the previous stored values intact. Individual shortcuts remain required;
the General switch disables them together.

Login controls read `SMAppService` directly instead of trusting the old stored
Boolean. Restoring app defaults retains that legacy field and leaves login
registration, language, update preferences and OS permissions untouched.

PermissionStore retains its existing monitoring and pending-hide recovery policy.
The settings adapter only checks permissions. Accessibility uses the library's
system-settings guidance without a second AX prompt. Full Disk Access appears
only on macOS 27; failed probes remain unknown. Request Access presents the shared
confirmation before invoking the existing registration helper. Open System
Settings only opens the pane, without invoking that helper.

## Sentry crash reporting

`MacAppDiagnosticsSentry` (Sentry Cocoa 9.30.0) is connected to the MenuBox
project. The public `Sources/MenuBox/Resources/SentryConfiguration.json` was
created with the library's `scripts/sentry-setup.py`; management credentials
remain in the developer Keychain/CI and never enter the app.

`MenuBoxDiagnostics` loads from `Bundle.module`, validates the real app bundle
identifier and version/build, and retains one service for the normal app process.
Recovery helpers, layout inspection and settings preview never start Sentry.
Without valid configuration the diagnostic section is omitted and invalid
configuration/start failures are logged locally without DSN/token contents.

General → Diagnostics uses the library's `CrashReportingPreference` and
`DiagnosticsSettingsSection`. Reports are off by default. Existing consent is
preserved; enabling/disabling takes effect after restart, and Reset Defaults does
not change consent. A startup failure does not change the stored preference.

The shared adapter limits events to fatal exceptions/crashes, strips its defined
user/request/extra fields and disables performance/session/network/breadcrumb
collection. Crash stacks, app/OS/device metadata still leave the device when
reporting is enabled; do not describe this as fully anonymous. The adapter may
send cached crashes from earlier enabled runs after consent is enabled again.

The app build retains Sentry's SDK privacy manifest in `SentryResources.bundle`
and archives matching dSYMs under `dist/symbols/`, separated by version, build
and architecture. Sentry is statically linked; no Sentry runtime framework is
embedded. See [release symbol upload](releasing.md#sentry-symbols).

Management API project/DSN setup and offline SDK/consent tests are verified.
No intentional crash or report was sent to the production project. Actual crash
receipt and symbolication require a separately authorized development-project
crash test with a signed build.

## Build and verification

The app bundle script includes MenuBox, MacAppSettings and MacAppMainMenu resource
bundles and verifies Mach-O minimum OS 13.0 and the selected SDK version. It keeps
the existing Sparkle framework embedding and signing flow.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build_app.sh arm64
```

Settings UI can be checked without touching real preferences, menu bar visibility,
permissions, login registration, hotkeys or updater networking:

```sh
dist/MenuBox.app/Contents/MacOS/MenuBox --menubox-settings-preview --preview-smoke
dist/MenuBox.app/Contents/MacOS/MenuBox --menubox-settings-preview --preview-light
dist/MenuBox.app/Contents/MacOS/MenuBox --menubox-settings-preview --preview-dark --preview-compact --preview-page permissions
```

Supported preview pages are `general`, `display`, `shortcuts`, `permissions`,
`updates`, and `about`. Use `-MacAppLibrary.language ko` or
`-MacAppLibrary.language en` for a process-only language override. Preview data
uses a temporary preferences suite removed on normal termination. The smoke
checks all six destinations, minimizing/restoring, closing/reopening and retaining
the accessory activation policy. Preview service states are fixtures; real OS
permissions, login registration and update installation require separate manual
verification with a properly signed app.
