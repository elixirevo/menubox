cask "menubox" do
  arch arm: "arm64", intel: "x86_64"

  version "1.4.2"
  sha256 arm:   "2266fa83b8a3aad47387fce1c14eefc4650c3012e7cb3342b172e63ab94cb894",
         intel: "c7013679eff7563f57dddedb4a28ad1a814583b7115d2c1cd0f78ddc5cac5daa"

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
