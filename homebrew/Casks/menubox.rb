cask "menubox" do
  arch arm: "arm64", intel: "x86_64"

  version "1.1.0"
  # Set these to the checksums of the renamed release artifacts before publishing.
  sha256 arm:   "REPLACE_WITH_ARM64_RELEASE_SHA256",
         intel: "REPLACE_WITH_X86_64_RELEASE_SHA256"

  url "https://github.com/elixirevo/menubox/releases/download/v#{version}/MenuBox-#{version}-#{arch}.dmg"
  name "MenuBox"
  desc "Native macOS menu bar utility for hiding and opening status bar apps"
  homepage "https://github.com/elixirevo/menubox"

  depends_on macos: ">= :ventura"

  app "MenuBox.app"

  uninstall quit: "com.elixirevo.MenuBox"

  zap trash: [
    "~/Library/Preferences/com.elixirevo.MenuBox.plist",
  ]
end
