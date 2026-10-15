#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

mode="${1:-}"
app="build/SwapBot.app"

if [[ "$mode" == "--dmg" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  binary="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SwapBot"
else
  swift build -c release
  binary=".build/release/SwapBot"
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp Resources/Info.plist "$app/Contents/"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$app/Contents/Info.plist"
fi
codesign --force --sign - "$app"
echo "Built $app"

if [[ "$mode" == "--install" ]]; then
  dest="$HOME/Applications/SwapBot.app"
  pkill -x SwapBot 2>/dev/null && sleep 0.5 || true
  rm -rf "$dest"
  cp -R "$app" "$dest"
  touch "$dest"
  open "$dest"
  echo "Installed and launched $dest"
fi

if [[ "$mode" == "--dmg" ]]; then
  staging="build/dmg"
  rm -rf "$staging" build/SwapBot.dmg
  mkdir -p "$staging"
  cp -R "$app" "$staging/"
  ln -s /Applications "$staging/Applications"
  hdiutil create -volname SwapBot -srcfolder "$staging" -ov -format UDZO build/SwapBot.dmg
  rm -rf "$staging"
  echo "Built build/SwapBot.dmg"
fi
