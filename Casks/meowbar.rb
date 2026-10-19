# Homebrew cask for MeowBar.
#
# To publish: create a repo named "homebrew-meowbar" under debugged-me, push
# this file to Casks/meowbar.rb there, and users can then:
#   brew tap debugged-me/meowbar
#   brew install --cask meowbar
cask "meowbar" do
  version "1.3"
  sha256 :no_check

  url "https://github.com/debugged-me/MeowBar/releases/download/v#{version}/MeowBar.dmg"
  name "MeowBar"
  desc "Claude Code and Codex usage limits in your menu bar"
  homepage "https://github.com/debugged-me/MeowBar"

  app "MeowBar.app"

  zap trash: [
    "~/Library/Application Support/MeowBar",
    "~/Library/Preferences/com.meowbar.app.plist",
  ]
end
