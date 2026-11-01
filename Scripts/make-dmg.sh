#!/bin/zsh
# Builds a Release video-converter.app and packages it as build/VideoConverter-<version>.dmg
# with a drag-to-Applications window. Needs `brew install create-dmg`.
#
#   VERSION=1.2.0 Scripts/make-dmg.sh          # version defaults to MARKETING_VERSION in the project
#   SIGN_IDENTITY="Developer ID Application: …" Scripts/make-dmg.sh   # defaults to ad-hoc ("-")
set -euo pipefail
root="${0:A:h}/.."
cd "$root"

build=build
sign="${SIGN_IDENTITY:--}"
version_args=()
[[ -n "${VERSION:-}" ]] && version_args=(MARKETING_VERSION="$VERSION")

rm -rf "$build/dmg" && mkdir -p "$build/dmg"
xcodebuild build -project video-converter.xcodeproj -scheme video-converter -configuration Release \
    -derivedDataPath "$build/DerivedData" -destination 'generic/platform=macOS' \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$sign" DEVELOPMENT_TEAM="" \
    $version_args

app="$build/DerivedData/Build/Products/Release/video-converter.app"
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")

# Retina-aware background: a multi-resolution TIFF from the 1x and 2x renders.
swift Scripts/dmg-background.swift "$build/dmg/bg.png" 1
swift Scripts/dmg-background.swift "$build/dmg/bg@2x.png" 2
tiffutil -cathidpicheck "$build/dmg/bg.png" "$build/dmg/bg@2x.png" -out "$build/dmg/bg.tiff"

dmg="$build/VideoConverter-$version.dmg"
rm -f "$dmg"
# Icon positions match the slots drawn by dmg-background.swift (600x400 window).
create-dmg \
    --volname "Video Converter" \
    --background "$build/dmg/bg.tiff" \
    --window-size 600 400 \
    --icon-size 112 \
    --text-size 13 \
    --icon video-converter.app 150 200 \
    --hide-extension video-converter.app \
    --app-drop-link 450 200 \
    --no-internet-enable \
    "$dmg" "$app"

hdiutil verify "$dmg"
echo "$dmg"
