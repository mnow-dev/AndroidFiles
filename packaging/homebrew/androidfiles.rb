cask "androidfiles" do
  version "0.2.0"
  sha256 "deebd0d8275f4b44db28f08b33a44a3f828d71f0733f9dddfa09734e1e066a1f"

  url "https://github.com/mnow-dev/AndroidFiles/releases/download/v#{version}/AndroidFiles-v#{version}-macos.dmg"
  name "AndroidFiles"
  desc "Fast, reliable Android phone backups & space cleanup over ADB"
  homepage "https://github.com/mnow-dev/AndroidFiles"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "AndroidFiles.app"

  zap trash: [
    "~/Library/Application Support/AndroidFiles",
    "~/Library/Preferences/com.mnow.androidFiles.plist",
  ]
end
