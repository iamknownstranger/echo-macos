#!/bin/bash
# Build a Finder-launchable Apple silicon application, distribution ZIP, and drag-and-drop DMG.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building Echo Music for macOS (Release arm64)..."
build_args=(-c release --triple arm64-apple-macosx14.0 --scratch-path .build/package)
swift build "${build_args[@]}"
bin="$(swift build "${build_args[@]}" --show-bin-path)/EchoMusic"

mkdir -p build
stage="$(mktemp -d "$PWD/build/.package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

app="$stage/Echo Music.app"
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources" "$stage/Echo.iconset"

echo "==> Packaging application bundle..."
install -m755 "$bin" "$app/Contents/MacOS/EchoMusic"
cp Info.plist "$app/Contents/"
cp ../LICENSE "$resources/"

if [[ -n "${APP_VERSION:-}" ]]; then
    echo "==> Injected version: $APP_VERSION"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$app/Contents/Info.plist"
fi
if [[ -n "${APP_BUILD:-}" ]]; then
    echo "==> Injected build number: $APP_BUILD"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$app/Contents/Info.plist"
fi

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" ../assets/Echo-new.png --out "$stage/Echo.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" ../assets/Echo-new.png --out "$stage/Echo.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$stage/Echo.iconset" -o "$resources/Echo.icns"

echo "==> Codesigning application bundle..."
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --options runtime --entitlements EchoMusic.entitlements --sign "$CODESIGN_IDENTITY" "$app"
else
    codesign --force --entitlements EchoMusic.entitlements --sign - "$app"
fi

codesign --verify --deep --strict "$app"
lipo "$app/Contents/MacOS/EchoMusic" -verify_arch arm64

echo "==> Creating distribution ZIP..."
ditto -c -k --keepParent "$app" "$stage/Echo-Music-arm64.zip"

echo "==> Creating drag-and-drop DMG..."
dmg_stage="$stage/dmg"
mkdir -p "$dmg_stage"
cp -R "$app" "$dmg_stage/"
ln -s /Applications "$dmg_stage/Applications"
hdiutil create -volname "Echo Music" -srcfolder "$dmg_stage" -ov -format UDZO "$stage/Echo-Music-arm64.dmg"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$stage/Echo-Music-arm64.dmg"
fi

# Optional Notarization pipeline if credentials are configured
if [[ -n "${KEYCHAIN_PROFILE:-}" ]]; then
    echo "==> Submitting DMG for Apple notarization via profile..."
    xcrun notarytool submit "$stage/Echo-Music-arm64.dmg" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$stage/Echo-Music-arm64.dmg"
elif [[ -n "${NOTARY_KEY:-}" ]] && [[ -n "${NOTARY_ISSUER:-}" ]]; then
    echo "==> Submitting DMG for Apple notarization via API key..."
    xcrun notarytool submit "$stage/Echo-Music-arm64.dmg" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
    xcrun stapler staple "$stage/Echo-Music-arm64.dmg"
fi

# Rotate build output safely
if [[ -e "build/Echo Music.app" ]]; then
    rm -rf "build/previous.app" || true
    mv "build/Echo Music.app" "build/previous.app"
fi
mv "$app" build/
mv -f "$stage/Echo-Music-arm64.zip" build/
mv -f "$stage/Echo-Music-arm64.dmg" build/
rm -rf "build/previous.app" || true

echo "==> Build and Packaging Completed Successfully!"
echo "    App: $PWD/build/Echo Music.app"
echo "    ZIP: $PWD/build/Echo-Music-arm64.zip"
echo "    DMG: $PWD/build/Echo-Music-arm64.dmg"
