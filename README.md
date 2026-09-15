# MenuBox 📦

![Platform](https://img.shields.io/badge/Platform-macOS-lightgrey.svg)
![Swift](https://img.shields.io/badge/Swift-5.0-orange.svg)
![License](https://img.shields.io/badge/License-MIT-blue.svg)

<img src="./icon.png" alt="MenuBox Icon" width="160" />

**MenuBox** is a lightweight, native macOS menu bar utility that keeps your crowded status bar under control. Place the tape marker after the icons you want to hide, then use the box icon or shortcuts to hide, reveal, or open those menu bar apps from a compact floating Box UI.

## ✨ Features

* **Menu Bar Icon Hiding:** Hide status bar icons to the left of the tape marker without quitting the underlying apps.
* **Tape Marker Workflow:** Use the tape icon as the boundary that decides which menu bar icons belong in MenuBox.
* **Compact Box UI:** Open a floating macOS glass-style Box UI that shows hidden menu bar apps as icons.
* **App Window Activation:** Left-click an app icon in Box UI to bring that app's window forward when supported.
* **Native Menu Access:** Right-click an app icon in Box UI to request its real status-item menu, including menus created on click. MenuBox reads the generated menu through Accessibility and displays it beside the icon.
* **Unsupported App Feedback:** Apps that cannot open a window or expose a usable native menu are shown as unsupported.
* **Auto-Hide:** Automatically hide menu bar icons again after a configurable delay.
* **Configurable Icon Grid:** Choose how many Box UI icons appear per row.
* **Optional Box UI Alerts:** Turn Box UI alert text on or off. When alerts are off, the Box UI trims its lower spacing.
* **Configurable Shortcuts:** Change or disable global shortcuts from Settings.
* **Launch at Login:** Start MenuBox automatically when you sign in.
* **Lightweight & Native:** Built with Swift and AppKit. No Electron.

## ⌨️ Shortcuts

| Shortcut | Action |
| --- | --- |
| `Option + B` | Toggle hidden menu bar icons |
| `Command + B` | Toggle Box UI |

*You can change shortcuts from Settings > General > Shortcuts.*
*You can disable all shortcuts with Settings > General > Shortcuts > Enable shortcuts.*
*If a shortcut conflicts with another app, choose a less common combination or disable MenuBox shortcuts.*

## 🚀 Installation & Build

MenuBox is built with Swift Package Manager and a small app-bundle build script.

### Install via Homebrew

Once a release is published and the cask is added to `elixirevo/tap`, install with:

```bash
brew tap elixirevo/tap
brew install --cask menubox
```

If you already tapped `elixirevo/tap`, this also works:

```bash
brew install --cask menubox
```

### Prerequisites

* macOS 13.0 or later
* Xcode Command Line Tools (`xcode-select --install`)

### Build Steps

1. Clone the repository:

   ```bash
   git clone https://github.com/elixirevo/menubox.git
   cd menubox
   ```

2. Build the Swift executable:

   ```bash
   swift build
   ```

3. Build the macOS app bundle:

   ```bash
   ./scripts/build_app.sh arm64 # Use x86_64 for Intel Macs.
   ```

4. The built application will be located at:

   ```text
   dist/MenuBox.app
   ```

5. Move it to your Applications folder:

   ```bash
   mv dist/MenuBox.app /Applications/
   ```

### Build DMGs

Build separate app bundles and DMGs for Apple Silicon and Intel:

```bash
./scripts/build_dmg.sh arm64
./scripts/build_dmg.sh x86_64
```

This creates:

```text
dist/MenuBox-1.1.0-arm64.dmg
dist/MenuBox-1.1.0-x86_64.dmg
```

You can override release metadata when needed:

```bash
APP_VERSION=1.1.0 APP_BUILD=111 ./scripts/build_dmg.sh arm64
```

Calculate the SHA-256 checksums with `shasum -a 256 dist/MenuBox-*.dmg`.

### Prepare a Homebrew Release

Before publishing the Homebrew cask:

1. Upload both `dist/MenuBox-1.1.0-arm64.dmg` and `dist/MenuBox-1.1.0-x86_64.dmg` to the GitHub release `v1.1.0` in `elixirevo/menubox`.
2. Copy `homebrew/Casks/menubox.rb` into the `elixirevo/homebrew-tap` repository.
3. Replace the two `REPLACE_WITH_*_RELEASE_SHA256` placeholders with the corresponding DMG checksums.
4. Update the cask `version` when releasing a new app version.

## 🔒 Permissions

MenuBox requires:

1. **Accessibility:** Required to discover menu bar status items and open supported native menus from Box UI.

If Accessibility permission does not apply after rebuilding the app, remove the old MenuBox entry from System Settings > Privacy & Security > Accessibility, then add `dist/MenuBox.app` again.

When upgrading from the former app name, MenuBox imports saved app settings and menu bar positions on first launch. Its bundle identifier is now `com.elixirevo.MenuBox`; re-enable Accessibility, Screen Recording (if used), and Launch at Login for the renamed app as needed.

*Note: MenuBox works locally on your Mac. It does not send menu bar data or app information over the network.*

## 🧭 Usage

1. Launch MenuBox.
2. Move the tape icon with macOS Command-drag so it sits to the right of the menu bar icons you want to hide.
3. Click the box icon or press `Option + B` to hide or show those icons.
4. Right-click the box icon or press `Command + B` to open Box UI.
5. In Box UI:
   * Left-click an app icon to open its app window when supported.
   * Right-click an app icon to open its native menu when supported.
6. Right-click the tape icon to open Settings or quit MenuBox.

## ⚠️ Limitations

macOS does not provide a public API for taking ownership of third-party menu bar icons. MenuBox uses the same general hiding approach as menu bar spacer utilities: it moves the tape marker to push selected icons out of the visible menu bar area.

Box UI support depends on what each app exposes through Accessibility and native menu APIs. Some apps show a window, some expose an `NSMenu`, and some do neither in a way MenuBox can safely control.

Hidden-menu forwarding leaves the spacer and pointer in place. It uses WindowServer event routing and a runtime-resolved private API for window-local event coordinates; compatibility can change with macOS updates. MenuBox reports `Menu unavailable` if the app does not produce a readable menu. See [native menu behavior and verification](docs/box-native-menus.md).

## 🛠 Contributing

Contributions are welcome. If you have ideas for new features, bug fixes, or improvements, feel free to open an issue or submit a pull request.

1. Fork the project
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a pull request

## 📄 License

Distributed under the MIT License. See `LICENSE` for more information.
