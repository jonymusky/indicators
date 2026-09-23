cask "indicators" do
  version "0.2.0"
  sha256 "875cf342667a9f14283fbfd34abe7eb769bae0c54915f0192faaec189476b90a"

  url "https://github.com/jonymusky/indicators/releases/download/v#{version}/Indicators.zip"
  name "Indicators"
  desc "AI usage and cost in the menu bar: live rate limits for Claude, OpenAI and Gemini, costs from local logs"
  homepage "https://indicators.jonymusky.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Indicators.app"
  binary "#{appdir}/Indicators.app/Contents/MacOS/indicators-cli"
  binary "#{appdir}/Indicators.app/Contents/MacOS/indicators-mcp"

  postflight_steps do
    # The app is ad-hoc signed; clear the quarantine flag so Gatekeeper does not block the first launch.
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Indicators.app"]
  end

  zap trash: [
    "~/Library/Application Support/Indicators",
    "~/Library/Preferences/com.jonymusky.indicators.plist",
  ]
end
