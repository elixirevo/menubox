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

The historical disappearance of both own controls under the removed assessment implementation was not independently isolated to one cause. The new backend never changes MenuBox's app-wide allowed flag; it hides only its own marker using `NSStatusItem.isVisible`.

## Implementation

- `NativeMenuBarPreferences` uses the actual `group.com.apple.controlcenter` container and Foundation's private `NSUserDefaults._initWithSuiteName:container:` initializer. It first requires an ordinary file read with user-approved Full Disk Access, validates the existing plist schema, and edits only selected records. No Apple-only entitlement or TCC database edit is used.
- `NativeMenuBarSnapshot` reads MenuBarAgent hosting groups on every display, distinguishes the box from the marker, and resolves narrow-display overflow from a non-overlapping reference display with matching membership and sides.
- `MenuBarSectionPlanner` selects items wholly left of the marker. Mixed-side applications, inconsistent display membership, ambiguous geometry and system items on the left are rejected before mutation.
- Selected app records are checked for helper/executable attribution and collateral effects on visible right-side items. If a live selected record owner's own identity is missing, its bundle location is appended without removing existing locations. This correction is retained on reveal; the previous allowed flags are restored.
- `NativeMenuBarHiding` saves a recovery journal, writes application visibility changes and hides its own marker in the same main-actor pass. One verification loop then checks the selected apps and marker are absent while the box and right-side controls remain. This removes the separate verification wait that delayed the marker. Rapid toggles cancel stale operations. Failures restore visibility.
- Box UI retains the selected applications and marker boundary while the marker is hidden. It reveals native items before requesting their menus.
- Focus changes verify the hidden section. Application, display and Space changes restore it before recalculating membership.
- `NativeMenuBarRecovery` restores prior visibility on show, normal exit and next launch. A second copy of the installed executable proves its own preferences access, then waits for the main process's lifetime pipe to close. Parent crashes trigger journal recovery.
- The last 80 state transitions are retained locally in `~/Library/Application Support/MenuBox/Diagnostics/native-hiding.log` to distinguish user show/hide commands from verification failures and environment changes.

## Verification

- Release compilation and strict bundle signature validation passed.
- XCTest: **28 passed, one opt-in native-menu test skipped**. Tests cover section boundaries, mixed-side/helper attribution, stale launcher ownership, preservation of unrelated settings, recovery, missing protected controls, hidden marker behavior and system relayout.
- Marker timing update: rebuilt, installed and reran the same tests successfully. In 34 live samples over 16 seconds, box-click reveal and the subsequent auto-hide restored then hid all 14 currently selected apps. The marker disappeared before the last applications finished disappearing, with no separate marker verification delay; the final sample retained the box and Focus on all displays. Evidence: `artifacts/macos27/research/marker-sync/`. These AX samples do not establish frame-level synchronization across processes.
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

This backend controls an application's menu items across all displays. It cannot independently hide one of the same app's items when its items span both sides of the marker. It also cannot selectively hide a system control on the left.

The store has no atomic compare-and-set API. Changed bytes are checked before writes and unrelated edits are merged during recovery, but an external write of the same value to a selected application cannot be distinguished from the existing value. Avoid concurrently editing selected apps' menu bar visibility during a hide/reveal transaction.

AX frame/identity checks are not a universal pixel-visibility oracle. The live tests verify hosted membership, control interaction and layout; they do not establish compatibility with every fullscreen, overflow or display configuration.

## Public API distinction

Apple's macOS 27 [`AEAssessmentConfiguration.allowedMenuBarItems`](https://developer.apple.com/documentation/automaticassessmentconfiguration/aeassessmentconfiguration/allowedmenubaritems) controls the menu bar during an assessment; it is not the per-app backend used here. [`NSStatusItem.isVisible`](https://developer.apple.com/documentation/appkit/nsstatusitem/isvisible) controls an app's own item and is used only for MenuBox's marker.

## Read-only reproduction

```sh
swift tools/menu-bar-snapshot.swift > /tmp/menubox-snapshot.json
```

The invoking tool needs Accessibility permission. The script reads menu bar hosting frames and identifiers and stops at other apps' AXApplication proxies. It does not traverse document or window content. Its `insideBar` field means rectangle containment only; duplicate bar windows and overflow placeholders are retained as raw observations.
