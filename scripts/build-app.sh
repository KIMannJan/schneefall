#!/bin/zsh
# Builds build/Schneefall.app (universal: Apple silicon + Intel, ad-hoc signed).
# --install: replaces /Applications/Schneefall.app and launches it.
# --zip:     also writes build/Schneefall.zip for sharing.
# Icon: swift scripts/make-icon.swift icon.png, scale it with sips into AppIcon.iconset/
#       (icon_16x16.png … icon_512x512@2x.png), then: iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
set -euo pipefail
cd "${0:A:h}/.."

archs=(--arch arm64 --arch x86_64)
swift build -c release $archs
bin=$(swift build -c release $archs --show-bin-path)
app=build/Schneefall.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/Schneefall" "$app/Contents/MacOS/Schneefall"
cp Resources/Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
echo "built $app"

if [[ "${1:-}" == "--zip" ]]; then
  stage=build/Schneefall                      # folder with the app + install guide for friends
  rm -rf "$stage" build/Schneefall.zip
  mkdir -p "$stage"
  ditto "$app" "$stage/Schneefall.app"
  cp Resources/Anleitung.txt "$stage/"
  ditto -c -k --norsrc --noextattr --keepParent "$stage" build/Schneefall.zip   # no ._ metadata files
  echo "zipped build/Schneefall.zip"
fi

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Schneefall || true
  rm -rf /Applications/Schneefall.app
  cp -R "$app" /Applications/
  open /Applications/Schneefall.app
  echo "installed /Applications/Schneefall.app"
fi
