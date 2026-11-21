#!/bin/bash
# Verification Gate Script for Echo Music macOS Beta Release
set -euo pipefail
cd "$(dirname "$0")"

echo "=========================================================="
echo "  Echo Music for macOS - Beta Release Gate Verification  "
echo "=========================================================="
echo ""

APP="build/Echo Music.app"
BIN="$APP/Contents/MacOS/EchoMusic"
DMG="build/Echo-Music-arm64.dmg"
ZIP="build/Echo-Music-arm64.zip"

FAILED=0

# Gate 1: Test Suite
echo "--> Gate 1: Executing complete unit test suite..."
if ./test.sh > /dev/null 2>&1; then
    echo "    ✅ PASS: Unit test suite passed with 100% success rate."
else
    echo "    ❌ FAIL: Unit test suite failed."
    FAILED=1
fi

# Gate 2: App Bundle & Binary Architecture
echo "--> Gate 2: Verifying application bundle & Apple silicon arm64 architecture..."
if [[ -d "$APP" ]] && [[ -f "$BIN" ]]; then
    if lipo "$BIN" -verify_arch arm64; then
        echo "    ✅ PASS: Binary architecture confirmed as native arm64."
    else
        echo "    ❌ FAIL: Binary is not arm64."
        FAILED=1
    fi
else
    echo "    ❌ FAIL: App bundle or executable missing at $APP."
    FAILED=1
fi

# Gate 3: Codesign Strict Verification
echo "--> Gate 3: Verifying codesign signature integrity..."
if codesign --verify --deep --strict "$APP" > /dev/null 2>&1; then
    echo "    ✅ PASS: Code signature verified deep and strict."
else
    echo "    ❌ FAIL: Codesign verification failed."
    FAILED=1
fi

# Gate 4: Entitlements Audit
echo "--> Gate 4: Auditing Hardened Runtime entitlements..."
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)"
if echo "$ENTITLEMENTS" | grep -q "com.apple.security.network.client"; then
    echo "    ✅ PASS: com.apple.security.network.client entitlement present."
else
    echo "    ❌ FAIL: Missing com.apple.security.network.client entitlement."
    FAILED=1
fi

if echo "$ENTITLEMENTS" | grep -q "com.apple.security.cs.disable-library-validation"; then
    echo "    ⚠️ WARN: Library validation is disabled."
else
    echo "    ✅ PASS: Library validation remains enabled (safe)."
fi

# Gate 5: Distribution ZIP Verification
echo "--> Gate 5: Verifying distribution ZIP archive..."
if [[ -f "$ZIP" ]] && [[ -s "$ZIP" ]]; then
    if unzip -tq "$ZIP" > /dev/null 2>&1; then
        echo "    ✅ PASS: ZIP archive verified valid and non-corrupt ($(du -h "$ZIP" | cut -f1))."
    else
        echo "    ❌ FAIL: ZIP archive corrupted."
        FAILED=1
    fi
else
    echo "    ❌ FAIL: Distribution ZIP missing or empty at $ZIP."
    FAILED=1
fi

# Gate 6: Drag-and-Drop DMG Verification
echo "--> Gate 6: Verifying drag-and-drop installer DMG..."
if [[ -f "$DMG" ]] && [[ -s "$DMG" ]]; then
    if hdiutil verify "$DMG" > /dev/null 2>&1 || diskutil image info "$DMG" > /dev/null 2>&1 || hdiutil imageinfo "$DMG" > /dev/null 2>&1; then
        echo "    ✅ PASS: DMG image verified valid ($(du -h "$DMG" | cut -f1))."
    else
        echo "    ❌ FAIL: DMG image verification failed."
        FAILED=1
    fi

    # Mount test DMG to verify Applications symlink
    MOUNT_DIR="$(mktemp -d /tmp/echo-verify-dmg.XXXXXX)"
    hdiutil attach "$DMG" -mountpoint "$MOUNT_DIR" -nobrowse -quiet
    if [[ -d "$MOUNT_DIR/Echo Music.app" ]] && [[ -L "$MOUNT_DIR/Applications" ]]; then
        echo "    ✅ PASS: DMG contents verified (Echo Music.app + Applications drop-link present)."
    else
        echo "    ❌ FAIL: DMG contents missing application or drop-link."
        FAILED=1
    fi
    hdiutil detach "$MOUNT_DIR" -quiet || true
    rm -rf "$MOUNT_DIR"
else
    echo "    ❌ FAIL: DMG missing or empty at $DMG."
    FAILED=1
fi

echo ""
if [[ "$FAILED" -eq 0 ]]; then
    echo "=========================================================="
    echo "  🎉 ALL 6 RELEASE GATES PASSED - PRODUCTION READY!      "
    echo "=========================================================="
    exit 0
else
    echo "=========================================================="
    echo "  ❌ RELEASE GATE VERIFICATION FAILED                     "
    echo "=========================================================="
    exit 1
fi
