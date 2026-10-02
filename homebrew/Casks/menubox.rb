cask "menubox" do
  arch arm: "arm64", intel: "x86_64"

  version "1.4.1"
  sha256 arm:   "28f89cbe3317bc011726371096bb2a220eaf16542802c7017e0e43becc0fff66",
         intel: "e262b421c1af43874727e1d243c007f44df04e870bed198e8a9005a12e415e98"

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
