cask "androidfiles" do
  version "0.3.0"
  sha256 "0ad0fbfb8510de88c66a755035b26529b3c59dec1f8020be37192d6ed3695adb"

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
    "~/Library/Preferences/dev.mnow.androidfiles.plist",
  ]
end
