cask "menubox" do
  arch arm: "arm64", intel: "x86_64"

  version "1.3.0"
  sha256 arm:   "6faf322ffabcf8342a5cdcb8e676ec45384561bfc52f6d9524f9617fb47b87ca",
         intel: "f0181108bdd8b6468bf3f1d2b1010b17b55b75d9f20d1327546ea011d5b2ba43"

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
