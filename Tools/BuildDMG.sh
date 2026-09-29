#!/bin/zsh
# Builds the Release app with the persistent local identity and packs it into a signed DMG.
# Usage: Tools/BuildDMG.sh [--skip-build]
set -euo pipefail
cd "$(dirname "$0")/.."

identity='NetUnstick Local Code Signing'
derived='Artifacts/ReleaseDerivedData'
out='Artifacts/Distribution'

if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "\"$identity\""; then
    print -u2 "Brak tożsamości '$identity'. Uruchom Tools/CreateLocalSigningIdentity.sh."
    exit 1
fi

if [[ "${1:-}" != '--skip-build' ]]; then
    xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
        CODE_SIGNING_ALLOWED=YES ONLY_ACTIVE_ARCH=YES build 2>&1 | /usr/bin/grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED'
fi

app="$derived/Build/Products/Release/NetUnstick.app"
test -d "$app"
NetUnstick/TestSupport/check-helper-bundle.sh "$app" --require-stable-signing
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"

mkdir -p "$out"
staging="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/netunstick-dmg.XXXXXX")"
mount="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/netunstick-mount.XXXXXX")"
trap '/usr/bin/hdiutil detach "$mount" >/dev/null 2>&1 || true; /bin/rm -rf -- "$staging"; /bin/rmdir "$mount" 2>/dev/null || true' EXIT INT TERM
/usr/bin/ditto "$app" "$staging/NetUnstick.app"
/bin/ln -s /Applications "$staging/Applications"

dmg="$out/NetUnstick-$version-$build.dmg"
/bin/rm -f "$dmg"
/usr/bin/hdiutil create -volname "NetUnstick $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
/usr/bin/codesign --sign "$identity" "$dmg"
/usr/bin/codesign --verify --strict "$dmg"

# Verify the payload from the mounted image exactly as a user receives it.
/usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" >/dev/null
/usr/bin/codesign --verify --deep --strict "$mount/NetUnstick.app"
/usr/bin/codesign --verify --strict "$mount/NetUnstick.app/Contents/MacOS/NetUnstickHelper"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$mount/NetUnstick.app/Contents/Info.plist")" == "$version" ]]
/usr/bin/hdiutil detach "$mount" >/dev/null

/usr/bin/shasum -a 256 "$dmg"
print "DMG: $dmg"
