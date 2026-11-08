#!/usr/bin/env bash
# Updates homebrew/indicators.rb to a release version and its sha256, then (optionally) pushes it to the tap.
#   scripts/update-cask.sh 0.2.0            # rewrite the cask file
#   TAP=~/GitHub/homebrew-tap scripts/update-cask.sh 0.2.0   # also copy into the tap checkout
# When TAP is unset, the tap Homebrew itself cloned (brew tap jonymusky/tap) is used if present.
#   TAP= scripts/update-cask.sh 0.2.0      # only rewrite the cask file
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?version, e.g. 0.2.0}"
URL="https://github.com/jonymusky/indicators/releases/download/v$VERSION/Indicators.zip"
SHA="$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)"
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" homebrew/indicators.rb
echo "homebrew/indicators.rb → $VERSION ($SHA)"
if [ -z "${TAP+x}" ] && command -v brew >/dev/null; then
  BREW_TAP="$(brew --repository)/Library/Taps/jonymusky/homebrew-tap"
  [ -d "$BREW_TAP/.git" ] && TAP="$BREW_TAP"
fi
if [ -n "${TAP:-}" ]; then
  (cd "$TAP" && git pull -q --ff-only)
  mkdir -p "$TAP/Casks" && cp homebrew/indicators.rb "$TAP/Casks/indicators.rb"
  (cd "$TAP" && git add Casks/indicators.rb && git commit -qm "indicators $VERSION" && git push -q) && echo "pushed to tap"
fi
