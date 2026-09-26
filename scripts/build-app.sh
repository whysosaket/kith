#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"
swift build -c release

binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$repo_root/dist/Kith.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Library/LaunchDaemons"
cp Resources/Kith-Info.plist "$app_dir/Contents/Info.plist"
plutil -replace CFBundleExecutable -string KithApp "$app_dir/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string dev.kith.app "$app_dir/Contents/Info.plist"
plutil -replace CFBundleName -string Kith "$app_dir/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string Kith "$app_dir/Contents/Info.plist"
plutil -replace CFBundleDevelopmentRegion -string en "$app_dir/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string 0.1.0 "$app_dir/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string 14.0 "$app_dir/Contents/Info.plist"
plutil -replace LSUIElement -bool YES "$app_dir/Contents/Info.plist"
plutil -replace NSHighResolutionCapable -bool YES "$app_dir/Contents/Info.plist"
cp Resources/dev.kith.power.plist "$app_dir/Contents/Library/LaunchDaemons/dev.kith.power.plist"
cp Resources/Kith.icns Resources/KithMenuBarTemplate.png "$app_dir/Contents/Resources/"
cp "$binary_dir/KithApp" "$binary_dir/kith-event" "$binary_dir/KithPowerHelper" "$app_dir/Contents/MacOS/"

identity="${KITH_SIGN_IDENTITY:--}"
codesign --force --sign "$identity" --identifier dev.kith.power "$app_dir/Contents/MacOS/KithPowerHelper"
codesign --force --sign "$identity" --identifier dev.kith.event "$app_dir/Contents/MacOS/kith-event"
codesign --force --sign "$identity" --identifier dev.kith.app "$app_dir"
codesign --verify --deep --strict "$app_dir"
echo "Built $app_dir"
if [[ "$identity" == "-" ]]; then
    echo "Ad hoc signing used. Sign with an Apple-issued identity before enabling the privileged helper."
fi
