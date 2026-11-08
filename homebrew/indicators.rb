cask "indicators" do
  version "0.2.2"
  sha256 "01037454faaddcb2a3c94af2a8cfc7ab73ac3a622d9edadf78e88261ad6f4884"

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
