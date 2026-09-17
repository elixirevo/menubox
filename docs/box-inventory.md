# Box icon inventory on macOS 27

## Causes

- The scanner deduplicated by rectangle, role, title and description. Overflow icons can all have the same rectangle and blank labels. The recorded 14-item scan therefore became 12 entries. Owning processes were not part of the key.
- The shown-state Box classified membership using cached per-app AX coordinates and the current marker x coordinate. These observations can refer to different layouts or displays. Box therefore did not necessarily show the same section that the hiding backend selected.
- Native hiding skipped AX scans entirely while hidden or transitioning. Launch notifications can precede status-item registration; without subsequent reconciliation, the app was not discovered until revealing the section.
- Any nonempty scan replaced the whole cache, even when some applications had temporarily unavailable AX trees. Warmup retried only an entirely empty cache, and opening a nonempty Box suppressed its immediate refresh.

## Changes

- Identity uses the owning PID and bundle plus the AX identifier, or AX element equality when no identifier exists. Coordinates and blank labels no longer merge different apps. Different identified items from the same app remain separate.
- On macOS 27, a shown Box uses a fresh, validated `NativeMenuBarSnapshot` section plan. A hidden Box uses the hiding backend's applied application set, including during selected-app menu leases. An unresolved shown section yields no guessed membership. macOS 13–26 retain the coordinate-based section filter.
- Scans run while hidden. Launch/display notifications schedule delayed discovery, and a five-second periodic check catches icons registered later without another workspace notification. Reconciliation updates the hidden plan after a stable membership change.
- Inventory updates merge valid observations. Failed or incomplete AX queries preserve existing items. Two consecutive complete observations are needed to discard a missing item outside the applied hidden set; terminated or replaced process owners are removed immediately. Hidden items remain cached when their AX list disappears.
- Opening Box always requests a fresh scan. Passive refresh updates its existing panel, leaves an active menu alone, and applies deferred results when the interaction ends. It does not restart the auto-hide timer.

## Verification

The XCTest suite has 102 tests. With the read-only live inventory check enabled, 101 passed and one opt-in native-menu interaction test was skipped. The added regressions cover collapsed icons with identical geometry, owner-scoped identities, moved items, partial nonempty scans, confirmed removal, new apps while hidden, process termination/reuse, actual section membership despite stale coordinates, registration after the launch notification, and AX attributes returning a single element, an array, an empty array, or an invalid value.

Release compilation uses the macOS 26.5 SDK and succeeds. Strict signature validation passes for the installed bundle. The read-only live scanner found the requested hidden Claude, JetBrains Toolbox, wewi and Ollama owners, and the visible RunCat owner without changing visibility. A local fixture launched without an icon at 10:45:07 UTC, created its icon at 10:45:19, and was automatically added to the hidden plan by the 10:45:26 observation without a user reveal. A read-only scan found its item while hidden. It exited at 10:46:37. Final hosted snapshots retained the Box and right-side RunCat, kTranslate and RocketFuel. At 10:45:51, the installed Box exposed exactly 13 AX buttons: the 12 existing selected apps and the newly registered fixture. These labels exactly matched the applied hidden plan; right-side RunCat, kTranslate and RocketFuel were absent. No user reveal was logged during the fixture run. The Box closed before the fixture exited, so removal is covered by unit tests rather than a live Box observation. Local evidence is in `artifacts/macos27/inventory-fix-v2/`.

This inventory change does not implement moving an overflowed dynamic-menu icon into the visible menu bar. That is a separate menu-routing issue.

The first validation build incorrectly accepted only arrays for `AXExtrasMenuBar`, which commonly returns one AX element. That introduced an empty Box. The corrected build accepts both shapes; normalization regressions and a live scan were added before reinstalling.
