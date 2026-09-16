# Native menus in Box UI

## Behavior

Box UI first attempts to send a real right-button down/up pair to an individually addressable status-item window. This lets apps build their menu in their own event handler instead of requiring an `AXMenu` or an advertised `AXShowMenu` to exist before the click. If that route is unavailable, attached menus and explicit `AXShowMenu` actions remain usable without changing visibility.

The destination is resolved from the live Accessibility frame and the complete Core Graphics window list, including offscreen windows. On macOS 26, Control Center can host another application's status item. Matching requires the correct owner, status-window layer and enclosing frame; ambiguous matches are rejected.

The event's global location stays at the current pointer. Its window-local location addresses the status button. No spacer change, cursor warp or app-specific menu definition is involved. The session event route is necessary for hosted status items; directly posting to a process skips that routing on macOS 26.

After a native menu appears, MenuBox reads its actual items and dismisses the offscreen popup with `AXCancel`. It shows those items beside the Box icon. On selection, it opens the native menu again and executes the uniquely matching, enabled item through Accessibility. A missing, renamed, ambiguous or disabled command is rejected. Dismissal and replacement requests cancel pending work; a posted mouse down is always balanced with mouse up.

Existing directly exposed Accessibility menus remain available as a fallback. A posted click is observed for up to 1.5 seconds before falling back to attached contents, so an old attached menu cannot win a race with menu rebuilding. A failed request is described as inability to open the menu while hidden, rather than proof that the app has no menu. Successful event posting alone is not considered menu support. Diagnostics distinguish a missing event route, a missing explicit menu action, and a popup observation timeout.

## macOS 27 regression and remaining limitation (2026-09-16)

The previous macOS 27 branch bypassed `StatusItemEventRouter` entirely: it read attached menus and required an advertised `AXShowMenu` when no menu was attached. This regressed apps that only build or attach a menu in `rightMouseUp`. Both OS paths now use the same request sequence, including reacquisition before command execution.

There is a second, unresolved issue on macOS 27.0 (26A428). Read-only probes of the running apps found:

| App | Hidden item's AX actions | Individually addressable status window |
| --- | --- | --- |
| Launchpod | `AXPress` | Not found |
| JetBrains Toolbox | `AXPress` | Not found |
| Claude | `AXPress` | Not found |

Their hidden AX frames overlap at the overflow position. `_AXUIElementGetWindow` returns error `-25201`; their Core Graphics window lists do not contain an enclosing, individually sized status window. MenuBarAgent has shared menu-bar windows, but those cannot identify a hidden item using its overlapping frame. They must not be treated as interchangeable with macOS 26 Control Center status windows.

Launchpod's own source confirms that `rightMouseUp` attaches its menu temporarily, while the primary action opens its launcher. Sending `AXPress` would execute the wrong action. AppKit runtime inspection shows scene-based event forwarding on this OS, but an externally usable route to the specific hidden scene has **not** been established. Restoring the old router call does **not** by itself fix these apps on macOS 27. No claim of live Launchpod recovery is made.

The user explicitly chose to preserve hidden icons rather than temporarily reveal the selected app. No visibility fallback, guessed window ID, whole-menu-bar click, or app-specific menu is implemented. Previously verified attached menus remain supported. Earlier macOS 26 results below are historical evidence, not macOS 27 verification.

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

2026-09-16 validation: the Xcode `xctest` runner executed 62 tests: 61 passed and the opt-in live-menu test was skipped. The arm64 release build and staged app signature verification passed. The staged bundle is `artifacts/macos27/dynamic-menu-request/MenuBox.app`; `/Applications/MenuBox.app` was not replaced because Launchpod's macOS 27 route remains unresolved. Unit request tests are not evidence that a real macOS 27 scene received a click.

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

The live test checks actual menu generation, the pointer position and the hidden status-item frame. Keep the pointer still during that check. Use `app.remixdesign.LaunchOS` to run the same check for LaunchOS.
