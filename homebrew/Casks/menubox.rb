cask "menubox" do
  arch arm: "arm64", intel: "x86_64"

  version "1.2.0"
  sha256 arm:   "77d9ee9a89c9f189e394fb137355dbb76997fad863eb3d5f2b780796976e774a",
         intel: "e0886f4453bf421ef4dd382d7c52e92705f948b61f76b9bef0b5979a591fc6d5"

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
