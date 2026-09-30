cask "menubox" do
  arch arm: "arm64", intel: "x86_64"

  version "1.4.0"
  sha256 arm:   "4cd7103682573b25d35533d14d2d41d6ce75e439e564f48ca4aa95735b8ea6ba",
         intel: "6cec6fab9e99786dc5deda5261ded22eecd37a31ef2b21eff3f3c529dd406580"

  url "https://github.com/elixirevo/menubox/releases/download/v#{version}/MenuBox-#{version}-#{arch}.dmg"
  name "MenuBox"
  desc "Menu bar utility for hiding and opening status bar apps"
  homepage "https://github.com/elixirevo/menubox"

  depends_on macos: :ventura

  app "MenuBox.app"

  uninstall quit: "com.elixirevo.MenuBox"

  zap trash: [
    "~/Library/Application Support/MenuBox",
    "~/Library/Preferences/com.elixirevo.MenuBox.plist",
    "~/Library/Preferences/com.elixirevo.StatusBox.plist",
  ]
end
