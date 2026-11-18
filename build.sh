#!/bin/zsh
# Builds build/Sugrob.app for this Mac's processor, signed ad hoc for local use. Needs only the Command Line Tools.
# UNIVERSAL=1 builds for Apple silicon and Intel together, which needs the full Xcode.
set -euo pipefail
cd "$(dirname "$0")"

if [[ -n "${UNIVERSAL:-}" ]]; then
    flags=(-c release --arch arm64 --arch x86_64)
else
    flags=(-c release)
fi
swift build "${flags[@]}"
products="$(swift build "${flags[@]}" --show-bin-path)"

app=build/Sugrob.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# Swift Build stamps the binary with the deployment target as its SDK, and macOS then draws the app in its old
# look, without Liquid Glass.
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)
vtool -set-build-version macos "$minimum" "$(xcrun --sdk macosx --show-sdk-version)" -replace \
    -output "$app/Contents/MacOS/Sugrob" "$products/Sugrob"
cp Resources/Info.plist "$app/Contents/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
for strings in locales/*.strings; do
    lproj="$app/Contents/Resources/$(basename "$strings" .strings).lproj"
    mkdir -p "$lproj"
    plutil -convert binary1 -o "$lproj/Localizable.strings" "$strings"
done

codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"
