# MacAppEssentials integration

MenuBox consumes the local `../tools/library` checkout of
[MacAppEssentials](https://github.com/elixirevo/mac-app-essentials). The integration
uses the **v0.4.0** tag at revision
`c1105892a3b29800dd6ed7842d35a2acef092bee`.
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
  windows close and resumes unfinished onboarding on Finder/Spotlight reopen,
  otherwise opening settings. Settings never
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
the Keyboard Shortcuts switch disables them together.

Auto-hide and Box Icon controls are on Display, above the existing Box Icons and
Menu Bar Icons sections. Enable shortcuts is on Keyboard Shortcuts, above the
shared recorder, supplied through `AppSettingsView(shortcutsContent:)`. General
retains language, login behavior, diagnostics and reset. These are view changes;
stored keys, defaults, shortcut registration and existing values are unchanged.

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

MenuBox owns Korean and English terms in
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
The user subsequently requested mandatory explicit agreement on 2026-10-05;
the app now uses the package agreement module as described below. Reading the
support sheet remains separate from acceptance. The privacy templates are
authoring resources, not a completed MenuBox privacy policy.

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

### Previous package update verification (2026-10-04)

Settings relocation follow-up: MenuBox 195 tests and MacAppEssentials 79 tests
passed (two existing opt-in MenuBox tests skipped). The ARM64 `dist/MenuBox.app`
was rebuilt with signature/resource/SDK checks. Seven-page smoke passed. In the
isolated Korean/dark preview, General no longer contained the moved controls;
shortcut, auto-hide and Box UI toggles retained changes when switching pages.
English/light and Korean/dark views were checked at minimum window size. Real
user preferences were not changed by these previews.

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

The app bundle script includes MenuBox, MacAppSettings, MacAppMainMenu and
MacAppOnboarding resource bundles and verifies Mach-O minimum OS 13.0 and the selected SDK version. It keeps
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


## First-run onboarding and mandatory terms (2026-10-05)

`MacAppOnboarding` v0.4.0 is linked and its resource bundle is copied by
`build_app.sh`. The guide covers welcome, marker placement, Box UI, settings
(step 4), the full bundled terms (step 5), OS-specific permissions and optional
Sentry crash reports (only when configured). There are eight steps on macOS 27
with diagnostics configured, seven without the Full Disk Access step. Native
artwork preserves the mirrored box/tape direction in both appearances.

The user's explicit 2026-10-05 instruction supersedes the former read-only
onboarding policy. `.terms(TermsAgreementModel)` now requires an unchecked
acknowledgement followed by Agree and Continue. Reading, scrolling, checking
alone, closing, and prior onboarding completion never create acceptance.
Closing or pressing Escape before acceptance quits, even from an earlier guide
page. Afterwards, permissions and crash reporting remain separate choices;
closing optional setup does not revoke the accepted terms.

`MenuBoxTerms.agreementDocument()` uses the same complete localized resources as
Help & Support. The English/Korean documents follow the package legal templates
and existing MenuBox adaptations: free distribution, confirmed operator/contact,
GPL and brand policy, actual permissions, optional Sentry and Sparkle behavior.
Their text, version 1.1 and effective date 2026-10-04 are unchanged. No operator
address or public URL was invented. The Help & Support sheet remains read-only.

Acceptance is stored independently at `MenuBox.Terms.Acceptance`, containing the
stable document ID, version, language, acceptance date and full-text SHA-256.
Completion stays at `MenuBox.Onboarding.CompletedVersion` (flow version 1).
Only Finish writes completion; Help & Support → Show Guide replays without
clearing or downgrading completion or recording another acceptance. General
Restore Defaults preserves both terms acceptance and crash-report preference.

Completed users with missing or different-version acceptance see the standalone
`TermsAgreementWindowController`, without repeating the entire tour. Both flows
share the same model/store. A terms version change requires fresh explicit
acceptance; language changes alone do not. Failed/corrupt reads and failed writes
remain gated and expose the package's retry/quit behavior. Missing legal resources
show a retry/quit alert. Never silently delete or fabricate acceptance records.

`MenuBoxLaunchGate` starts services only after successful persisted acceptance,
once per launch. Before then, MenuBox does not install status items, menu commands,
global shortcuts, permission polling, automatic hiding, updater or Sentry SDK.
Settings/reopen route back to the required window, including when minimized.
Restoring previously changed system state on startup/termination remains allowed.
Configuration is read for the consent UI without initializing Sentry. Reporting
still depends on its separate consent at process launch; toggles take effect next
launch. Terms acceptance never enables it automatically.

Use `--menubox-onboarding-preview` for isolated UI verification, with
`--preview-step N`, `--preview-light`, `--preview-dark`, `--preview-smoke`, or
`--preview-terms-update` for the standalone agreement. Pass
`-MacAppLibrary.language ko` or `en` for a process-only language override.
The preview is visibly marked nonbinding, uses in-memory receipt/completion,
inert permission actions, and starts no updater, SDK, status items or shortcuts.
Step selection cannot skip an unaccepted terms page. Only this explicit fixture
may simulate acceptance during tests; real user acceptance is never automated.
The settings preview uses an accepted in-memory fixture for replay.

## Earlier v0.4.0 validation

Before the mandatory-consent change, local build 1.5.0 (151) passed 200 app tests
(198 passed, two existing opt-in checks skipped), 84 library tests and isolated
onboarding/settings smokes. This historical result predates the new gate.

## Mandatory-consent validation (2026-10-05)

- App suite: 204 tests, 202 passed and two existing opt-in checks skipped.
  Coverage includes no consent from completion/checking alone, independent
  completion and diagnostics choices, reset preserving receipts, corrupt/wrong
  version/failed persistence keeping services blocked, and once-only startup.
- Isolated onboarding smoke: quit before acceptance, no implicit receipt,
  acknowledgement reset on reopen, minimized window restore, explicit fixture
  acceptance, optional permissions/diagnostics and accessory policy passed.
  Existing seven-page settings smoke also passed.
- Native UI: Korean/dark step 4 is settings, step 5 shows full terms with unchecked
  acknowledgement and disabled Agree and Continue; explicitly labeled in-memory
  acceptance advances to the permission step. English/light standalone terms show
  the same gate and Escape quits. Real consent was not accepted by automation.
- Local ARM64 build 1.5.0 (152): `dist/MenuBox.app`. Developer ID signature,
  bundled terms/legal resources, SDK/minimum OS and matching dSYM checks passed.
  Screenshots are diagnostic artifacts in `artifacts/terms-consent-qa/`.
  No public release was created.
