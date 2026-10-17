#!/bin/zsh
# Builds the Release app with Developer ID and packs it into a signed,
# Finder-styled installer image: background with instructions, 128 pt icons, the app on
# the left, the Applications shortcut on the right, and the app icon as the volume icon.
# Usage: Tools/BuildDMG.sh [--skip-build]
# Finder briefly opens the image window while it records the layout; that is expected.
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${NETUNSTICK_SIGN_IDENTITY:-D6CDD9E6748C6D2AE7D9FAF9D48D5CCAC992630E}"
team='UGL4ZTH3C6'
derived='Artifacts/ReleaseDerivedData'
out='Artifacts/Distribution'
volume_name='NetUnstick'
# The background is 660 x 400 pt; the window bounds add the title bar so the whole picture shows.
window_x=200; window_y=120; window_width=660; window_height=430
app_x=165; app_y=175; applications_x=495; applications_y=175; icon_size=128

if [[ ! "$identity" =~ '^[[:xdigit:]]{40}$' ]]; then
    print -u2 'NETUNSTICK_SIGN_IDENTITY musi zawierać pełny SHA-1 certyfikatu Developer ID Application.'
    exit 1
fi
identity="$(print -r -- "$identity" | /usr/bin/tr '[:lower:]' '[:upper:]')"
identity_name="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -v hash="$identity" '$2 == hash {sub(/^[^"]*"/, ""); sub(/"$/, ""); print}')"
if [[ "$identity_name" != 'Developer ID Application: '*' ('$team')' ]]; then
    print -u2 "Brak tożsamości Developer ID Application zespołu $team o SHA-1 $identity. Sprawdź: security find-identity -v -p codesigning."
    exit 1
fi
if [[ -d "/Volumes/$volume_name" ]]; then
    print -u2 "Wolumen /Volumes/$volume_name jest zamontowany; wysuń go przed budową."
    exit 1
fi

if [[ "${1:-}" != '--skip-build' ]]; then
    xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
        CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
        ONLY_ACTIVE_ARCH=YES build 2>&1 | /usr/bin/grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED'
fi

app="$derived/Build/Products/Release/NetUnstick.app"
test -d "$app"
NetUnstick/TestSupport/check-helper-bundle.sh "$app" --require-developer-id
/usr/bin/codesign --verify --strict "-R=certificate leaf = H\"$identity\"" "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"

work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/netunstick-dmg.XXXXXX")"
mount=''
cleanup() {
    if [[ -n "$mount" && -d "$mount" ]]; then /usr/bin/hdiutil detach "$mount" -force >/dev/null 2>&1 || true; fi
    /bin/rm -rf -- "$work"
}
trap cleanup EXIT INT TERM

# 1. Staging: app, Applications shortcut, Retina background, volume icon.
staging="$work/staging"
/bin/mkdir -p "$staging/.background"
/usr/bin/ditto "$app" "$staging/NetUnstick.app"
/bin/ln -s /Applications "$staging/Applications"
/usr/bin/swiftc -O -o "$work/DMGBackground" Tools/DMGBackground/main.swift \
    -framework CoreGraphics -framework CoreText -framework ImageIO -framework UniformTypeIdentifiers
"$work/DMGBackground" "$work" "$version"
/usr/bin/tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" -out "$staging/.background/background.tiff"
# Keep the FSEvents daemon from writing its journal into the image.
/bin/mkdir -p "$staging/.fseventsd"
/usr/bin/touch "$staging/.fseventsd/no_log"

# 2. Writable image; Finder records the window layout into its .DS_Store.
rw="$work/rw.dmg"
/usr/bin/hdiutil create -volname "$volume_name" -srcfolder "$staging" -fs HFS+ -format UDRW -size 64m -ov "$rw" >/dev/null
/usr/bin/hdiutil attach -readwrite -noverify -noautoopen -plist "$rw" > "$work/attach.plist"
mount="$(/usr/bin/python3 -c 'import plistlib, sys
for entity in plistlib.load(open(sys.argv[1], "rb")).get("system-entities", []):
    if entity.get("mount-point"): print(entity["mount-point"]); break' "$work/attach.plist")"
if [[ ! -d "$mount" ]]; then print -u2 "Nie znaleziono punktu montowania obrazu roboczego."; exit 1; fi
disk_name="${mount:t}"
# No Finder flags on the app bundle: codesign --strict rejects Finder information as detritus.
/usr/bin/osascript <<EOS
tell application "Finder"
    tell disk "$disk_name"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {$window_x, $window_y, $((window_x + window_width)), $((window_y + window_height))}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $icon_size
        set text size of viewOptions to 14
        set label position of viewOptions to bottom
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "NetUnstick.app" of container window to {$app_x, $app_y}
        set position of item "Applications" of container window to {$applications_x, $applications_y}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOS
/bin/sleep 2
test -f "$mount/.DS_Store"
# The volume icon goes in after Finder is done: hdiutil skips .VolumeIcon.icns when it copies
# the source folder, and Finder deletes the file and clears the flag while it records the layout.
/bin/cp "$app/Contents/Resources/AppIcon.icns" "$mount/.VolumeIcon.icns"
/usr/bin/SetFile -a C "$mount"
if ! /usr/bin/GetFileInfo -a "$mount" | /usr/bin/grep -q 'C'; then print -u2 "Flaga własnej ikony wolumenu nie została ustawiona."; exit 1; fi
/bin/sync
/bin/sleep 2
for attempt in 1 2 3 4 5; do
    if /usr/bin/hdiutil detach "$mount" >/dev/null 2>&1; then mount=''; break; fi
    /bin/sleep 2
done
[[ -z "$mount" ]]

# 3. Compressed read-only image, signed with the same identity.
/bin/mkdir -p "$out"
dmg="$out/NetUnstick-$version-$build.dmg"
/bin/rm -f "$dmg"
/usr/bin/hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg" >/dev/null
/usr/bin/codesign --sign "$identity" --timestamp "$dmg"
/usr/bin/codesign --verify --strict "$dmg"
/usr/bin/codesign --verify --strict "-R=certificate leaf = H\"$identity\"" "$dmg"
/usr/bin/codesign -dvvv "$dmg" 2>&1 | /usr/bin/grep -q '^Timestamp='

# 4. Verify the payload from the mounted image exactly as a user receives it.
verify="$work/verify"
/bin/mkdir -p "$verify"
/usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$verify" "$dmg" >/dev/null
mount="$verify"
NetUnstick/TestSupport/check-helper-bundle.sh "$verify/NetUnstick.app" --require-developer-id
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$verify/NetUnstick.app/Contents/Info.plist")" == "$version" ]]
test -L "$verify/Applications"
test -f "$verify/.DS_Store"
test -f "$verify/.background/background.tiff"
test -f "$verify/.VolumeIcon.icns"
/usr/bin/hdiutil detach "$verify" >/dev/null
mount=''

/usr/bin/shasum -a 256 "$dmg"
print "DMG: $dmg"

# Keep the helper digest as release evidence. Developer ID carries a stable Team ID;
# the system still controls whether a migration or update requires approval.
helper_cdhash="$(/usr/bin/codesign -dvvv "$app/Contents/MacOS/NetUnstickHelper" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')"
record="$out/helper-cdhash.txt"
if [[ -f "$record" && "$(/bin/cat "$record")" != "$helper_cdhash" ]]; then
    print "Binarka helpera zmieniła się od poprzedniego wydania ($(/bin/cat "$record") -> $helper_cdhash). Tożsamość Developer ID zespołu: $team; o zatwierdzeniu elementu tła decyduje macOS."
elif [[ -f "$record" ]]; then
    print "Helper bez zmian od poprzedniego wydania ($helper_cdhash)."
else
    print "Zapisano cdhash helpera ($helper_cdhash) jako punkt odniesienia dla kolejnych wydań."
fi
print -r -- "$helper_cdhash" > "$record"
