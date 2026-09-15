# Native menus in Box UI

## Behavior

Box UI first sends a real right-button down/up pair to the status item's window. This lets apps build their menu in their own event handler instead of requiring an `AXMenu` to exist before the click.

The destination is resolved from the live Accessibility frame and the complete Core Graphics window list, including offscreen windows. On macOS 26, Control Center can host another application's status item. Matching requires the correct owner, status-window layer and enclosing frame; ambiguous matches are rejected.

The event's global location stays at the current pointer. Its window-local location addresses the status button. No spacer change, cursor warp or app-specific menu definition is involved. The session event route is necessary for hosted status items; directly posting to a process skips that routing on macOS 26.

After a native menu appears, MenuBox reads its actual items and dismisses the offscreen popup with `AXCancel`. It shows those items beside the Box icon. On selection, it opens the native menu again and executes the uniquely matching, enabled item through Accessibility. A missing, renamed, ambiguous or disabled command is rejected. Dismissal and replacement requests cancel pending work; a posted mouse down is always balanced with mouse up.

Existing directly exposed Accessibility menus remain available as a fallback. An absent menu is reported as `Menu unavailable`; successful event posting alone is not considered menu support.

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
