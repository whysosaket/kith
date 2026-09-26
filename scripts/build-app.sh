#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
bundle_id=app.trykith.kith
cd "$repo_root"
swift build -c release

binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$repo_root/dist/Kith.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Library/LaunchDaemons"
cp Resources/Kith-Info.plist "$app_dir/Contents/Info.plist"
plutil -replace CFBundleExecutable -string KithApp "$app_dir/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$app_dir/Contents/Info.plist"
plutil -replace CFBundleName -string Kith "$app_dir/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string Kith "$app_dir/Contents/Info.plist"
plutil -replace CFBundleDevelopmentRegion -string en "$app_dir/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string 14.0 "$app_dir/Contents/Info.plist"
plutil -replace LSUIElement -bool YES "$app_dir/Contents/Info.plist"
plutil -replace NSHighResolutionCapable -bool YES "$app_dir/Contents/Info.plist"
cp "Resources/$bundle_id.power.plist" "$app_dir/Contents/Library/LaunchDaemons/"
cp Resources/Kith.icns Resources/KithMenuBarTemplate.png "$app_dir/Contents/Resources/"
cp "$binary_dir/KithApp" "$binary_dir/kith-event" "$binary_dir/KithPowerHelper" "$app_dir/Contents/MacOS/"

# Hardened runtime blocks library injection into Kith and its root helper.
# Only Apple-issued identities (KITH_SIGN_IDENTITY) can use Apple's secure timestamp.
local_identity="${KITH_LOCAL_IDENTITY:-Kith Local Signing}"
identity="${KITH_SIGN_IDENTITY:-}"
sign_flags=(--force --options runtime)
if [[ -n "$identity" ]]; then
    sign_flags+=(--timestamp)
elif security find-identity -p codesigning | grep -Fq "\"$local_identity\""; then
    identity="$local_identity"
else
    identity="-"
fi
codesign "${sign_flags[@]}" --sign "$identity" --identifier "$bundle_id.power" "$app_dir/Contents/MacOS/KithPowerHelper"
codesign "${sign_flags[@]}" --sign "$identity" --identifier "$bundle_id.event" "$app_dir/Contents/MacOS/kith-event"
codesign "${sign_flags[@]}" --sign "$identity" --identifier "$bundle_id" "$app_dir"
codesign --verify --deep --strict "$app_dir"
echo "Built $app_dir"
if [[ "$identity" == "-" ]]; then
    echo "Ad hoc signing used; macOS privacy grants reset on every rebuild."
    echo "Run scripts/create-signing-identity.sh once to keep them."
fi
