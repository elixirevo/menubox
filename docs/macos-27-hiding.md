# macOS 27 hiding: implementation and verification

Tested on macOS 27.0 (26A428), 2026-09-16, with a built-in display and two external displays.

## Required behavior

The box always remains available. A hide request conceals the marker and the applications to its left. Items to the right, including Focus, remain. Clicking the box again restores the marker and the hidden applications. The underlying applications keep running.

## Causes found

1. The old 10,000-point `NSStatusItem` spacer no longer displaced neighboring icons in the observed MenuBarAgent layout.
2. An earlier assessment-mode replacement applied a global restriction. Its fixed system-item allowlist still concealed Focus and did not implement a geometric section. That implementation was removed.
3. The first per-app implementation selected ChatGPT correctly (`com.openai.codex`), but its macOS `menuItemLocations` record contained only an old Launchpod executable. Setting that record's `isAllowed` flag did not affect ChatGPT's own item. Other selected apps disappeared; the all-targets-hidden check then failed and restored them after its retry period. A live snapshot sequence and transaction journal reproduced this behavior.
4. Removing a newly introduced owner location while restoring its allowed flag left MenuBarAgent unable to re-enable that location. Recovery now retains the corrected ownership association and restores the original visibility values.
5. The initial verifier required identical x coordinates. MenuBarAgent's transient `plus` indicator can shift adjacent icons without a visibility failure. Verification now checks protected identities, containment and ordering. The box and Focus remain required.
6. Ad-hoc signed rebuilds invalidate TCC grants. System Settings can display an enabled switch while `tccd` rejects the executable's current code hash. Both Device Control and Data Access and Full Disk Access must refer to the installed build.

7. Laptop-only layouts can report several overflow icons at the same coordinates. Requiring an expanded external display rejected an otherwise clear left-of-marker section. Planning now accepts overlap confined to the left section, while still rejecting marker/control overlap and applications on both sides.
8. There were no sleep/wake observers, and focus verification called `show()`, clearing the user's hidden intent. The first wake fix restored settings on sleep and reapplied after wake, causing a visible gap. The current implementation retains the applied transaction through sleep and verifies it in place on wake. Transient failures retry with a bound; explicit reveal cancels retries.
9. System items on the left previously rejected the entire hide request. Supported system controls now use individual preferences with the same recovery journal as applications.

The historical disappearance of both own controls under the removed assessment implementation was not independently isolated to one cause. The new backend never changes MenuBox's app-wide allowed flag; it hides only its own marker using `NSStatusItem.isVisible`.

## Implementation

- `NativeMenuBarPreferences` uses the actual `group.com.apple.controlcenter` container and Foundation's private `NSUserDefaults._initWithSuiteName:container:` initializer. It first requires an ordinary file read with user-approved Full Disk Access, validates the existing plist schema, and edits only selected records. No Apple-only entitlement or TCC database edit is used.
- `NativeMenuBarSnapshot` reads MenuBarAgent hosting groups on every display, distinguishes the box from the marker, and validates each display’s boundary, including laptop-only overflow placeholders wholly left of the marker.
- `MenuBarSectionPlanner` selects items wholly left of the marker. Mixed-side applications, inconsistent display membership and ambiguous marker/control geometry are rejected before mutation. Individual system identifiers are selected separately from application bundles.
- `NativeSystemMenuBarPreferences` maps Now Playing, Text Input, Sound, Wi-Fi, Battery, Focus, Screen Mirroring, Display and Timer to individual visibility preferences. Control Center values use the current-host domain; Text Input uses its own domain. Original values, including absent defaults, are journaled and restored. Transient `plus` and `com.apple.menuextra.audiovideo` indicators stay visible and are excluded from section membership and verification; their appearance cannot block app hiding or trigger a restore. Other unsupported system identifiers fail before mutation; no global restriction or app-wide MenuBarAgent flag is used.
- Selected app records are checked for helper/executable attribution and collateral effects on visible right-side items. If a live selected record owner's own identity is missing, its bundle location is appended without removing existing locations. This correction is retained on reveal; the previous allowed flags are restored.
- `NativeMenuBarHiding` saves a recovery journal, writes application visibility changes and hides its own marker in the same main-actor pass. One verification loop then checks the selected apps and marker are absent while the box and right-side controls remain. This removes the separate verification wait that delayed the marker. Rapid toggles cancel stale operations. Write failures restore visibility; temporary AX unavailability while checking an applied transaction retains its hidden settings.
- Box UI retains the selected applications and marker boundary while the marker is hidden. It first tries readable native menus without revealing icons. If unavailable on macOS 27, it briefly shows only the selected app, generates its menu, reads attached or app-owned on-screen AX popup roots, keeps the original popup when it is already beside Box, and uses a proxy for menus anchored elsewhere. Native presentation holds the selected-app visibility lease until dismissal and lets the app execute commands directly. Forwarded events preserve the physical pointer; host/menu observation uses short initial intervals. Selection reacquires the current menu and executes its AX action before releasing the visibility lease. Other hidden apps and the marker remain hidden. See [native menu behavior and verification](box-native-menus.md).
- Sleep cancels observation without restoring preferences, the marker, or the original recovery journal. Wake immediately checks the retained transaction. Duplicate wake/focus/application/display/Space notifications coalesce without resetting ongoing work. Reappearing targets use the existing journal to reapply hidden values; unavailable AX trees retry without revealing. A changed display or membership must be observed twice before restoring the marker and replanning. Explicit reveal cancels all pending checks.
- `NativeMenuBarRecovery` restores prior visibility on show, normal exit and next launch. A second copy of the installed executable proves its own preferences access, then waits for the main process's lifetime pipe to close. Parent crashes trigger journal recovery.
- The last 80 state transitions are retained locally in `~/Library/Application Support/MenuBox/Diagnostics/native-hiding.log` to distinguish user show/hide commands from verification failures and environment changes.

## Verification

- Release compilation and strict bundle signature validation passed.
- Current XCTest: **79 passed, one opt-in native-menu test skipped** (including menu forwarding, detached-popup geometry and transient activity-indicator regressions). Added regression tests cover laptop-only overflow, sleep during a transition, wake retries, explicit cancellation, focus recovery, individual system controls and their journal recovery. Earlier baseline: 28 passed, one skipped. Tests cover section boundaries, mixed-side/helper attribution, stale launcher ownership, preservation of unrelated settings, recovery, missing protected controls, hidden marker behavior and system relayout.
- Marker timing update: rebuilt, installed and reran the same tests successfully. In 34 live samples over 16 seconds, box-click reveal and the subsequent auto-hide restored then hid all 14 currently selected apps. The marker disappeared before the last applications finished disappearing, with no separate marker verification delay; the final sample retained the box and Focus on all displays. Evidence: `artifacts/macos27/research/marker-sync/`. These AX samples do not establish frame-level synchronization across processes.
- Installed combined verification: 13 applications plus the left-side Text Input icon and marker disappeared; the box and right-side Now Playing, Wi-Fi and Battery remained. Reveal restored all selected items. Killing the main process restored all 13 applications and Text Input within 0.81 seconds through the recovery helper. Evidence: `artifacts/macos27/research/system-control-visibility/combined-result.json`.
- System-control verification on the laptop: direct CFPreferences writes hid and restored Now Playing and Text Input while app icons stayed hidden. System Settings comparisons also confirmed the visibility keys for Sound, Wi-Fi, Battery, Focus, Screen Mirroring, Display and Timer. Evidence: `artifacts/macos27/research/system-control-visibility/`.
- The previous wake implementation reproduced a visible gap: wake at 15:50:36, hidden confirmation at 15:50:42, another environment-triggered restore at 15:50:46, and hidden confirmation at 15:50:50. Evidence: `artifacts/macos27/research/wake-failure/wake-delay-observed.log`. The current build adds tests that require no restoration through sleep, duplicate wake events, temporary missing AX data, and wake flag reapplication. Actual sleep/wake and Box UI command execution are awaiting the user-assisted check; these are not yet claimed as verified.
- Retained-state build: 301 hosted AX samples over 179.71 seconds kept all 14 selected applications and the marker absent, the box present, and the same recovery journal throughout. Eight of the 14 hidden apps exposed attached menus in a read-only check. Evidence: `artifacts/macos27/research/retain-wake-menu/`. This observation window did not contain a sleep/wake cycle or menu command execution.
- The initial Ollama programmatic hide/restore passed twice and reclaimed 32 points on both external displays.
- The final installed build selected and hid ChatGPT along with the other left-side applications. The marker disappeared; the box and right-side Focus remained.
- A box left-click restored ChatGPT and both MenuBox controls on all three displays, and removed the transaction journal. A second left-click hid the section again.
- A forced-parent-termination test restored the transaction's selected applications and removed its journal through the helper.
- With Finder/desktop frontmost, 56 samples over 60.64 seconds showed all 12 selected apps and the marker absent, with the box and Focus present on every display. There were no failures.
- The final build was forcibly terminated while hiding 12 apps, including ChatGPT. The helper restored every selected app on all displays and removed its journal within 1.32 seconds.
- Full-screen Spaces and monitor hot-plug have not been tested in this run.

Ignored local evidence:

- `artifacts/macos27/research/repro-return`: original rollback reproduction and affected preference records.
- `artifacts/macos27/research/final-shown.json`: successful ChatGPT/marker restoration.
- `artifacts/macos27/research/final-stability`: repeated hidden-state snapshots and result summary.
- `artifacts/macos27/research/forced-exit`: first helper crash-recovery verification.
- `artifacts/macos27/research/final-crash-recovery`: final recovery of all 12 selected apps, including ChatGPT.

During testing, the user's five-second auto-hide was temporarily disabled to distinguish explicit reveal from automatic re-hide. It was restored to enabled with its original five-second delay before relaunching the final installed build. `/Applications/MenuBox.app` and `dist/MenuBox.app` contain that tested build.

## Limits

The settings interface and storage format are private and can change in macOS updates. The new backend is enabled only on macOS 27; macOS 13–26 retain the spacer implementation. Later unrecognized versions report that hiding is unavailable.

This backend controls an application's menu items across all displays. It cannot independently hide one of the same app's items when its items span both sides of the marker. It supports only the system controls listed above; mandatory or unknown system controls are not assigned guessed preferences.

The store has no atomic compare-and-set API. Changed bytes are checked before writes and unrelated edits are merged during recovery, but an external write of the same value to a selected application cannot be distinguished from the existing value. Avoid concurrently editing selected apps' menu bar visibility during a hide/reveal transaction.

AX frame/identity checks are not a universal pixel-visibility oracle. The live tests verify hosted membership, control interaction and layout; they do not establish compatibility with every fullscreen, overflow or display configuration.

## Public API distinction

Apple's macOS 27 [`AEAssessmentConfiguration.allowedMenuBarItems`](https://developer.apple.com/documentation/automaticassessmentconfiguration/aeassessmentconfiguration/allowedmenubaritems) controls the menu bar during an assessment; it is not the per-app backend used here. [`NSStatusItem.isVisible`](https://developer.apple.com/documentation/appkit/nsstatusitem/isvisible) controls an app's own item and is used only for MenuBox's marker.

## Read-only reproduction

```sh
swift tools/menu-bar-snapshot.swift > /tmp/menubox-snapshot.json
```

The invoking tool needs Accessibility permission. The script reads menu bar hosting frames and identifiers and stops at other apps' AXApplication proxies. It does not traverse document or window content. Its `insideBar` field means rectangle containment only; duplicate bar windows and overflow placeholders are retained as raw observations.
