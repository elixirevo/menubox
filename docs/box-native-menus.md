# Native menus in Box UI

## Behavior

On macOS 27, MenuBox first tries to obtain the menu while its icon stays hidden. If no readable menu is available, it temporarily enables **only the selected app**, waits for its visible host, and sends a right click there. Other hidden apps, system items, and the marker retain their hiding settings. If the app-owned popup already opens beside the clicked Box icon, MenuBox leaves that original menu open. The app handles selection directly, and the selected icon is rehidden when the menu closes. Otherwise the source popup is dismissed and Box displays a proxy; selecting a proxy command reacquires the current native command.

Temporary visibility uses the existing recovery journal without overwriting the original settings. Focus notifications cannot undo the temporary operation; completion, timeout, cancellation, or sleep rehides the app. An explicit user reveal invalidates the temporary operation so its later cleanup cannot hide icons again. A shared controlling record that would expose another app is refused. The setting is per app, so multiple icons belonging to the selected app can appear together.

Box UI first reads the current attached Accessibility menu. If it contains menu entries, Box displays them directly without posting input or opening the source popup. This applies with icons shown and hidden. Selection rereads the live menu and requires a unique, enabled matching command; it does not reuse cached menu contents.

An absent attached menu does not mean the app is unsupported. MenuBox then sends a right-button down/up pair to an addressable status-item window, allowing dynamic apps to build the menu in their event handler. Explicit `AXShowMenu` remains a fallback when the click route is unavailable. Once a click has been posted, observation still waits for the generated popup before considering attached contents again.

The destination is resolved from the live Accessibility frame and the complete Core Graphics window list, including offscreen windows. On macOS 26, Control Center can host another application's status item. Matching requires the correct owner, status-window layer and enclosing frame; ambiguous matches are rejected.

On macOS 26 and 27, the event's global location stays at the current pointer and its window-local location addresses the status button. The session event route lets the system forward hosted status items to their owning app. On macOS 27, a visible icon is verified using the live system hit-test PID and MenuBarAgent group's ownership and geometry. The button hit area may extend slightly outside its group (observed for Claude), so the group must contain its center rather than every edge. A stale hidden frame is never sufficient. The resolved destination is reused when posting one right-button down/up pair, without warping or restoring the physical pointer. No app-specific menu definitions are used.

Host readiness is checked every 16 ms within a three-second limit. After a click, the first ten menu checks use 10 ms intervals, followed by 70 ms intervals for slower apps. The original 1.5-second observation allowance is retained. These intervals do not include Accessibility call time. Detached popup discovery accepts an app-owned menu at the recorded click point as well as near the status icon, because a cursor-preserving event can anchor the source menu beside Box. Ownership, layer and size checks still apply.

After a native menu appears, MenuBox matches its AX root to an app-owned on-screen popup window. A popup starting within the Box area stays open: there is no `AXCancel`, replacement menu, or second right click when the user selects a command. Its window lifetime holds the selected-app visibility lease. Natural dismissal only releases the lease; cancellation, replacement or sleep also cancels the menu.

Menus that are offscreen or anchored away from Box retain the proxy path: MenuBox reads their actual items, dismisses the source with `AXCancel`, and displays those items beside the Box icon. On proxy selection, it opens the native menu again and executes the uniquely matching, enabled item through Accessibility. A missing, renamed, ambiguous or disabled command is rejected. Dismissal and replacement requests cancel pending work; a posted mouse down is always balanced with mouse up.

A posted click is observed for up to 1.5 seconds before falling back to attached contents, so an intermediate attached menu cannot win a race with a dispatched rebuild. The initial no-input read uses the live AX tree, not a stored snapshot. Apps that only refresh menu contents in their opening delegate may expose their last prepared state until opened; there is no claim that reading AX runs every app's menu-generation code. A failed request is described as inability to open this app's menu, rather than proof that the app has no menu. Successful event posting alone is not considered menu support. Diagnostics distinguish a missing event route, a missing explicit menu action, and a popup observation timeout.

## macOS 27 regression and remaining limitation (2026-09-16)

The previous macOS 27 branch bypassed `StatusItemEventRouter` entirely: it read attached menus and required an advertised `AXShowMenu` when no menu was attached. This regressed apps that only build or attach a menu in `rightMouseUp`. Both OS paths now use the same request sequence, including reacquisition before command execution.

The fully hidden route has a second limitation on macOS 27.0 (26A428). Read-only probes of the running apps found:

| App | Hidden item's AX actions | Individually addressable status window |
| --- | --- | --- |
| Launchpod | `AXPress` | Not found |
| JetBrains Toolbox | `AXPress` | Not found |
| Claude | `AXPress` | Not found |

Their hidden AX frames overlap at the overflow position. `_AXUIElementGetWindow` returns error `-25201`; their Core Graphics window lists do not contain an enclosing, individually sized status window. MenuBarAgent has shared menu-bar windows, but those cannot identify a hidden item using its overlapping frame. They must not be treated as interchangeable with macOS 26 Control Center status windows.

Launchpod's own source confirms that `rightMouseUp` attaches its menu temporarily, while the primary action opens its launcher. Sending `AXPress` would execute the wrong action. AppKit runtime inspection shows scene-based event forwarding on this OS, but an externally usable route to the specific hidden scene has **not** been established. Restoring the old router call does **not** by itself fix these apps on macOS 27. An already attached Launchpod menu was subsequently read and its Settings command executed in live testing. That result does not establish a route for generating its menu while fully hidden.

The initial user preference was to preserve every hidden icon. The user subsequently authorized a compromise: temporarily reveal the selected app when its dynamic menu cannot be obtained while hidden. The new fallback follows that scope and does not restore the whole section. Earlier macOS 26 results below are historical evidence, not macOS 27 verification.

## Detached popup discovery on macOS 27

Claude creates a real `AXMenu` in an app-owned layer-101 window, but omits it from the status item's menu attributes, the application's `AXChildren`, and `AXFocusedUIElement`. The earlier observer therefore timed out while the native popup remained at the menu bar, instead of handing its contents to Box.

The observer now falls back to hit-testing the selected app's nearby on-screen popup windows. It follows the hit menu item's parent chain to the actual `AXMenu`, reads its live contents, and retains that root for `AXCancel`. This status-menu path requires matching ownership, popup layer and bounded geometry, and refuses foreign AX menu roots. Main windows and unrelated menus cannot become the source. The Box presentation path now keeps an original popup that is already beside Box. It identifies that popup by window ID and owner PID, and holds the visibility lease until it closes. Only the fallback proxy path cancels the original and recreates its commands; proxy selection reacquires the menu before its AX action.

### Earlier live verification: selected-menu-v4 (2026-09-16, macOS 27.0 / 26A428)

- Claude: Box right-click generated the menu, read 7 source entries, dismissed the original, and displayed its commands in MenuBox's own popup next to the Box icon.
- WindowServer check: no visible Claude window remained while the proxy menu was open. The visible menu belonged to MenuBox (layer 101, x=1112, y=76), beside its Box panel (x=1091, y=41).
- Choosing “사용량 설정…” reacquired the live menu and executed its AX action. Claude opened its usage/upgrade screen; both source and proxy popup windows closed afterward.
- 69 menu-bar samples covered menu opening and command execution. Only Claude appeared temporarily, the marker stayed absent, and the original recovery journal remained byte-for-byte unchanged.
- Evidence: `artifacts/macos27/research/selected-menu/`, including `v4-verification.json`, menu-window snapshots, popup hit-test observations and test/build logs.


### Cursor and latency verification (2026-09-16, macOS 27.0 / 26A428)

The v4 fallback physically moved the pointer to the menu bar, waited between mouse events, then restored it. The current route removes that movement and observes host/menu readiness more frequently. The older window-local attempt had been judged by an observer that missed Claude's detached popup; it was not proof that event delivery failed.

- Installed `menu-ux-v2`: Claude generated seven source entries and displayed its commands in Box. Temporary reveal through menu read took 365–422 ms across observed requests; this is not an end-to-end click-to-render benchmark.
- Opening: 1,263 read-only samples across 18 seconds recorded exactly one pointer position. The Claude source popup appeared near that pointer for approximately 78 ms before being cancelled; the Box proxy followed. There was no trip to the menu bar.
- Selection: “사용량 설정…” executed successfully and opened Claude's usage/upgrade screen. Another 1,292 samples recorded exactly one pointer position. The source popup was visible for approximately 93 ms.
- Final `menu-ux-v3` adds recorded-click-point popup geometry support, covered by a regression test. After installation and existing-permission refresh, startup hid all 13 selected apps and the marker while retaining Box and the transient activity indicator. The final bundle and `dist/MenuBox.app` have matching hashes; the menu timing measurements above came from v2.
- A separate run included user pointer motion and is retained as raw evidence, not counted as a stationary-pointer check.
- Evidence: `artifacts/macos27/research/menu-ux/`. The selected icon and source popup may still appear briefly; this implementation reduces their duration and removes cursor travel, rather than promising zero visible frames. Other apps' timing depends on their menu generation.

## Direct native presentation (2026-09-16)

The remaining double-menu effect came from deliberately cancelling Claude's visible original menu and constructing a MenuBox proxy. When the original popup starts within the Box area, MenuBox now keeps that same window open and lets Claude handle commands itself. Moving the pointer within Box while menu generation is pending does not force a proxy. Popups starting at the menu bar or outside Box still use the compatibility path.

Installed `direct-native-v2` verification:

- Claude opened one app-owned layer-101 popup at (1082, 66), beside Box at (1044, 41). WindowServer samples retained the same window ID (5831); no MenuBox layer-101 proxy appeared during that request.
- A later read-only AX inspection found the same original menu still open, including its “사용량 설정…” command. Opening no longer performs cancel-and-reopen.
- Hosted snapshots across three bar replicas showed only Claude added during the menu session. Other hidden apps and the marker remained absent; Box remained present. The recovery journal was byte-for-byte unchanged.
- Native command selection verification was skipped at the user's request. A usage/upgrade screen was observed, but it is not counted as proof of selection through the new path. Natural-close logs did confirm that the selected icon was rehidden after the native popup ended. The automation tool could read the popup through AX hit tests but could not click it because Claude omits it from `AXWindows`.
- Automated lifecycle tests cover natural dismissal, replacement/cancellation and one-time visibility cleanup. Geometry tests reject menu-bar popups and accept original menus in Box, including pointer movement and display-edge placement.
- Evidence: `artifacts/macos27/research/direct-native-menu/`.

## Avoiding source-menu flashes with visible icons (2026-09-16)

A live log reproduced this with wewi: `right-click posted`, a source popup at y=34, then a MenuBox proxy. Read-only inspection found seven attached AX menu entries before any request, and wewi's source assigns a persistent `NSStatusItem.menu` during refresh. Opening that source menu was unnecessary.

The request now reads the attached menu first. A readable menu goes directly to Box without posting a right click or `AXShowMenu`, regardless of whether its icon is hidden or expanded. Proxy selection rereads current contents through the same path and rejects removed, renamed, disabled or ambiguous commands. Menus are not cached. If the initial read is empty, the dynamic-menu generation path continues normally, including the single original-menu presentation for Claude.

This differs from the earlier broken implementation that rejected an empty pre-click menu. Empty now means “try generating the menu,” not “unsupported.” Tests cover both cases and ensure a late attached menu cannot replace a pending dynamic rebuild prematurely.

Apple documents [`AXShowMenu`](https://developer.apple.com/documentation/applicationservices/kaxshowmenuaction) as an action that displays a menu, and [`AXUIElementPerformAction`](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction) as a request to execute an element's action. Neither supplies a no-render option for another app's menu-generation callback. The implementation therefore avoids unnecessary generation rather than claiming it can invisibly render every third-party menu. Apps that create menus only during input still need that generation path; app-chosen anchoring can retain a visible source-popup limitation.

Installed `read-before-input-v1` verification on macOS 27.0 (26A428):

- The expanded-state snapshot contains wewi, the marker and Box in the primary hosted bar. Repeated wewi requests log `attached menu read without input`, seven entries and `nativeFrame=unavailable` for the Box proxy.
- Across 1,725 WindowServer samples over 25 seconds, no wewi-owned popup appeared. The trace includes repeated opening requests and user interaction with other apps; it is not a single-click latency or stationary-pointer measurement.
- Choosing wewi's “Open Settings” reread the attached menu without another right click, logged `forwarded=true`, and opened the actual “wewi Settings” window. Selection happened after the sampling interval, so its execution is verified by the action log and UI rather than that popup trace.
- Claude still followed `right-click posted` → seven entries → `native presentation` during observed user requests. This confirms the empty-menu generation fallback remains active; native command selection was not retested.
- The release build, installed app and `dist/MenuBox.app` have matching executable hashes. Evidence and scope notes are in `artifacts/macos27/research/read-before-input/verification.json`.

## Compatibility

`CGEventSetWindowLocation` and the event window-number field are private implementation details. The symbol is resolved at runtime; the forwarding path is disabled if it is unavailable. No process injection or modification of another app is used.

Verified on macOS 26.6.2 with multiple displays:

| Check | Result |
| --- | --- |
| Launchpod: generate menu while hidden | Passed |
| Launchpod: preserve pointer and hidden icon position | Passed |
| Box UI → Launchpod menu → Settings window | Passed |
| LaunchOS 2.3.0: open menu from Box UI | User confirmed working |

An isolated LaunchOS probe did not observe a menu during investigation. Subsequent user testing confirmed that both apps' menus open in Box UI.

## Tests

The request tests cover menus created only after a right click without `AXShowMenu`, delayed menu rebuilding instead of stale attached contents, failed delivery versus actual menu appearance, bounded observation, and cancellation during routing or before a late popup.

2026-09-16 validation: the Xcode `xctest` runner executed 80 tests: 79 passed and the opt-in live-menu test was skipped. Tests also cover selected-app-only visibility, unchanged recovery settings, cancellation, explicit user reveal, sleep, host geometry and keeping a generated menu alive through command execution. The arm64 release build and app signature verification passed. The selected-app fallback is installed at `/Applications/MenuBox.app`; the staged bundle is `artifacts/macos27/read-before-input-v1/MenuBox.app`. Unit request tests are not evidence that a real macOS 27 scene received a click.

Use an Xcode toolchain for XCTest:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The live test is opt-in because it interacts with an already-running app. It opens and dismisses a menu without selecting a command:

```sh
MENUBOX_MENU_TEST_BUNDLE_ID=app.launchpod.Launchpod \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter testLiveNativeMenuWithoutMovingCursor
```

This low-level test checks actual menu generation, the final pointer position and status-item frame. It does not perform the macOS 27 selected-app visibility lease; the installed-app checks above cover that complete flow. Keep the pointer still during that check. Use `app.remixdesign.LaunchOS` to run the same check for LaunchOS.
