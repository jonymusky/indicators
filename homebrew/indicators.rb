cask "indicators" do
  version "0.2.1"
  sha256 "0ce39c37a9942cde12cc998acfc37e44ff9ab202ce7e02d4aa65193824e838d2"

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

  caveats <<~EOS
    Indicators is ad-hoc signed (no Apple Developer ID yet). If macOS blocks the first
    launch, right-click Indicators.app → Open once, or clear the quarantine flag:
      xattr -dr com.apple.quarantine "#{appdir}/Indicators.app"
  EOS

  zap trash: [
    "~/Library/Application Support/Indicators",
    "~/Library/Preferences/com.jonymusky.indicators.plist",
  ]
end
