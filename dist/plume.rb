cask "plume" do
  # Sample formula. Plume does not host a Homebrew tap.
  # If you'd like to maintain a community cask, copy this file into
  # homebrew-cask (https://github.com/Homebrew/homebrew-cask) as a PR.
  #
  # Update `version` and replace the `sha256` placeholder with the
  # output of:  shasum -a 256 Plume.dmg

  version "2.6.0"
  sha256 "0e5e18b075596f6108010dabbd8bf55a80f4128ad8d575842bda47f05dc1b756"

  url "https://github.com/zabrodsk/plume/releases/download/v#{version}/Plume.dmg"
  name "Plume"
  desc "Markdown editor for the satisfaction of typing"
  homepage "https://github.com/zabrodsk/plume"

  app "Plume.app"

  zap trash: [
    "~/Library/Preferences/io.plume.app.plist",
    "~/Library/Caches/io.plume.app",
    "~/Library/WebKit/io.plume.app",
  ]
end
