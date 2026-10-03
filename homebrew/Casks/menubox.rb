cask "menubox" do
  arch arm: "arm64", intel: "x86_64"

  version "1.4.3"
  sha256 arm:   "af46c7e3d7b1f313dc3572eafbaed7f360bbdc7940ec59615b4375b4a20569c9",
         intel: "db7565b01788003b7a747f0a08a15d82958e54d1f9b530e28ebb8be597b29ad6"

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
