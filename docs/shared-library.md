# MacAppEssentials integration

MenuBox consumes the local `../tools/library` checkout of
[MacAppEssentials](https://github.com/elixirevo/mac-app-essentials). The integration
uses v0.3.0 plus the subsequent development updates and settings content extensions
at revision `a5771978e8f196aa8f1712a96d076c1c9dc0e371`. This is not a new tagged release.
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
  The marker context menu includes manual and automatic update checking, using
  this same model; opening the menu refreshes enabled/check states, and automatic
  preference write failures open Software Update to show the error.
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

## v0.3.0 settings migration

The local path dependencies consume the updated checkout directly; Package.resolved
continues to pin only Sparkle and Sentry, whose versions have not changed.
`AppSettingsView` now receives both required support and reset models. The settings
pages explicitly place Help & Support before About, and the native Help menu opens
that destination using `SettingsPageID.support`.

Support opens MenuBox's GitHub README and issue tracker. The library's diagnostic
preview/copy/save contains only app name, version, build, macOS version and direct
distribution channel. It does not attach logs or Sentry data or submit an issue.
Reset continues to restore only MenuBox settings after confirmation and retains
language, login registration, update preferences, crash-reporting consent and OS
permissions.

MacAppOnboarding remains optional and is not linked; MenuBox retains its existing
permission-guidance startup flow. MenuBox now owns Korean and English terms in
`Sources/MenuBox/Resources/{ko,en}.lproj/TermsOfUse.txt`, adapted from the package's
legal template. Settings → Help & Support → Read Terms opens a read-only sheet with selectable
full text and a native Save panel. There is no separate legal-document sidebar page. It loads the current
app language from Bundle.module without a web request. Reading/saving does not
record acceptance, gate app features, or change Sentry consent. The operator confirmed there are no public document URLs. The shared support
page accepts app-owned sections through the backward-compatible `supportContent`
slot; MenuBox supplies its offline terms button there. `SupportLegalLinks` remains
the API for finalized HTTPS documents when available. No privacy document or URL
is fabricated. Legacy terms destinations redirect to `SupportLegalLinks.settingsPageID`.

The document is version 1.1, effective 2026-10-04 (revised before publishing the new terms). The operator supplied the name
elixirevo, email elixirevo@gmail.com, Republic of Korea, and confirmed the app is
free. The text applies GPL-3.0-only with section 7 brand terms, preserves prior license grants, describes actual permissions,
Sparkle and optional Sentry reporting, and removes purchase/subscription clauses.
No business address, registration number, phone, privacy-policy URL or Sentry
retention/hosting location was supplied; none is invented. The functional privacy
summary is not a separate privacy policy. Legal review and any required operator
or privacy disclosures remain publication work; technical checks do not establish
legal sufficiency.

Template source: `../tools/library/docs/legal/` at revision 98735a0. Checked against
[GNU GPL version 3](https://www.gnu.org/licenses/gpl-3.0.html) and the template's
[official Korean liability/dispute provisions](https://law.go.kr/LSW/lsLinkCommonInfo.do?chrClsCd=010202&lsJoLnkSeq=1025032399).
Preserve prior terms in version control when changing the document and version.
The newly available TermsAgreement module remains unlinked: merely reading or
running this GPL app does not require a new acceptance gate. The privacy templates
are authoring resources, not a completed MenuBox privacy policy.

The bundle also includes LICENSE, LICENSING.md, TRADEMARKS.md and upstream notices
under Contents/Resources/Legal, opened by Show License Files. The bundle script
compares both packaged terms and legal notices with their source files, so a
missing, stale or truncated resource fails the build.

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

## Update verification (2026-10-04)

- MenuBox: 195 tests, 193 passed and two existing opt-in checks skipped.
- MacAppEssentials: 69 tests passed across the package's test targets.
- ARM64 release bundle, strict code signature, minimum OS/SDK and matching dSYM
  checks passed. The validation build is `artifacts/essentials-update/MenuBox.app`.
- Isolated settings smoke passed all seven pages, minimize/restore,
  close/reopen and accessory policy. English/light and Korean/dark support pages
  fit the minimum window size; the native Help command opens Support from About.
- No installed app replacement, real permission request, crash report or update
  installation was performed by the preview.

## Terms verification (2026-10-04)

- MenuBox: 197 tests, 195 passed and two existing opt-in checks skipped.
- Both localized terms load from app resources; locale resolution and template
  placeholder removal are covered. ARM64 release packaging verifies exact source
  equality for both bundled terms; strict signature and matching dSYM checks pass.
- Isolated eight-page settings smoke passes. Minimum-size Korean/dark and
  English/light views show the full document through the final paragraph.
- The native Save panel exported the Korean text, and byte comparison with the
  source passed. No acceptance or crash-report preference was changed.
- Build: `artifacts/terms-build/MenuBox.app`. No installed app was replaced.

## GPL and brand policy verification (2026-10-04)

- MenuBox: 197 tests, 195 passed and two existing opt-in checks skipped.
- ARM64 release build, strict code signature, minimum OS/SDK and matching dSYM
  checks passed. Build: `artifacts/gpl-build/MenuBox.app`.
- Both localized terms (version 1.1) and all four bundled legal documents match
  their source files. The GPL text matches the unmodified GNU GPL version 3 text.
- In an isolated Korean settings preview, **Show License Files…** opened the
  bundled Legal folder in Finder with LICENSE, LICENSING.md, TRADEMARKS.md and
  THIRD_PARTY_NOTICES.txt. The preview was then closed.
- No public release or installed app replacement was performed. The external
  MacAppEssentials license still needs to be established before public distribution;
  see [release requirements](releasing.md).

## Build and verification

### Latest package update verification (2026-10-04)

- The support integration and settings content extensions: MenuBox 195 tests passed,
  two existing opt-in checks skipped; MacAppEssentials 79 tests passed.
- Latest ARM64 app: **`dist/MenuBox.app`** (1.4.3, build 146). Release compilation,
  strict signature, minimum OS/SDK, matching dSYM and bundled legal resource
  equality checks passed. This is a local validation build, not a published release.
- Isolated smoke passed seven pages, legacy terms-to-support redirection,
  rejection of the removed custom terms page, minimize/restore, close/reopen and
  accessory policy. Korean/dark and English/light support views fit the minimum
  window size, without a separate terms sidebar item.
- The offline terms sheet opens and closes back to Support; the Korean final
  paragraph remains reachable. English Save Terms exported bytes identical to
  the source document, and Show License Files opened all four legal documents.
- The support and shortcut content extensions are committed in the shared package.
  README now checks out the exact revision; no additional patch is required.
- UI-only copies and exported verification text are under
  `artifacts/support-ui-verification/`. The final app remains in `dist/`.

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

`terms` is a compatibility alias for `support`. Supported preview arguments are `general`, `display`, `shortcuts`, `permissions`,
`updates`, `support`, `terms`, and `about`. Use `-MacAppLibrary.language ko` or
`-MacAppLibrary.language en` for a process-only language override. Preview data
uses a temporary preferences suite removed on normal termination. The smoke
checks all seven destinations, the legacy terms redirect, rejection of the removed
custom terms page, minimizing/restoring, closing/reopening and retaining
the accessory activation policy. Preview service states are fixtures; real OS
permissions, login registration and update installation require separate manual
verification with a properly signed app.
