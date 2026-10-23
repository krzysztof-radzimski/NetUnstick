#!/bin/zsh
# Developer ID installer for macOS 14+, Apple Silicon. Secrets stay in Keychain.
# Usage: Tools/BuildPKG.sh --notary-profile NetUnstick [--skip-build] [--update-feed]
#        Tools/BuildPKG.sh --prepare-only [--skip-build]
# Resume an existing submission without rebuilding or uploading again:
#        Tools/BuildPKG.sh --resume draft.pkg --submission-id UUID --notary-profile NetUnstick
set -euo pipefail
cd "$(dirname "$0")/.."

die() { print -u2 -- "$*"; exit 1; }
skip_build=false
prepare_only=false
update_feed=false
profile="${NETUNSTICK_NOTARY_PROFILE:-}"
resume=''
submission_id=''
while (( $# )); do
    case "$1" in
        --skip-build) skip_build=true; shift ;;
        --prepare-only) prepare_only=true; shift ;;
        --update-feed) update_feed=true; shift ;;
        --notary-profile|--resume|--submission-id)
            (( $# >= 2 )) || die "Brak wartości dla $1."
            case "$1" in
                --notary-profile) profile="$2" ;;
                --resume) resume="$2" ;;
                --submission-id) submission_id="$2" ;;
            esac
            shift 2 ;;
        *) die "Nieznany argument: $1" ;;
    esac
done
[[ "$prepare_only" == true || -n "$profile" ]] || die 'Podaj --notary-profile <profil z pęku kluczy> albo --prepare-only (pakiet niegotowy do dystrybucji).'
[[ -z "$submission_id" || -n "$resume" ]] || die '--submission-id wymaga --resume.'
[[ -z "$resume" || "$prepare_only" == false ]] || die '--resume nie łączy się z --prepare-only.'
[[ "$prepare_only" == false || "$update_feed" == false ]] || die '--update-feed wymaga pełnej notaryzacji, bez --prepare-only.'
[[ -z "$submission_id" || "$submission_id" =~ '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$' ]] || die 'Nieprawidłowy identyfikator zgłoszenia.'

team='UGL4ZTH3C6'
identity="${NETUNSTICK_SIGN_IDENTITY:-D6CDD9E6748C6D2AE7D9FAF9D48D5CCAC992630E}"
installer_name="Developer ID Installer: Krzysztof Radzimski ($team)"
installer_identity="${NETUNSTICK_INSTALLER_IDENTITY:-$installer_name}"
derived='Artifacts/ReleaseDerivedData'
out='Artifacts/Distribution'
/bin/mkdir -p "$out"
work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/netunstick-pkg.XXXXXX")"
trap '/bin/rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -z "$resume" ]]; then
    [[ "$identity" =~ '^[[:xdigit:]]{40}$' ]] || die 'NETUNSTICK_SIGN_IDENTITY musi być pełnym SHA-1 certyfikatu Developer ID Application.'
    identity="$(print -r -- "$identity" | /usr/bin/tr '[:lower:]' '[:upper:]')"
    identity_name="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -v hash="$identity" '$2 == hash {sub(/^[^\"]*\"/, ""); sub(/\"$/, ""); print}')"
    [[ "$identity_name" == 'Developer ID Application: '*' ('$team')' ]] || die "Brak certyfikatu Developer ID Application zespołu $team."
    installer_matches="$(/usr/bin/security find-identity -v -p basic | /usr/bin/awk -v name="$installer_name" -v wanted="$installer_identity" 'index($0, "\"" name "\"") && (wanted == name || toupper(wanted) == $2) {print $2}')"
    [[ "$installer_matches" =~ '^[[:xdigit:]]{40}$' ]] || die 'Brak jednoznacznej tożsamości Developer ID Installer z kluczem prywatnym. Ustaw NETUNSTICK_INSTALLER_IDENTITY na pełny SHA-1.'
    installer_identity="$installer_matches"

    if [[ "$skip_build" == false ]]; then
        build_log="$out/pkg-build.log"
        if ! /usr/bin/xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Release \
            -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
            CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" \
            DEVELOPMENT_TEAM="$team" ONLY_ACTIVE_ARCH=YES build > "$build_log" 2>&1; then
            /usr/bin/tail -n 70 "$build_log"
            die "Budowanie nie powiodło się. Pełny log: $build_log"
        fi
        print 'Release: BUILD SUCCEEDED'
    fi
    app="$derived/Build/Products/Release/NetUnstick.app"
    NetUnstick/TestSupport/check-helper-bundle.sh "$app" --require-developer-id
    /usr/bin/codesign --verify --strict "-R=certificate leaf = H\"$identity\"" "$app"
    [[ "$(/usr/bin/lipo -archs "$app/Contents/MacOS/NetUnstick")" == arm64 ]] || die 'Oczekiwano aplikacji arm64.'
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")" == 14.0 ]] || die 'Minimum aplikacji musi wynosić macOS 14.0.'
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
    build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
    [[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$build" =~ '^[0-9]+$' ]] || die 'Nieprawidłowa wersja wydania.'
    name="NetUnstick-$version-$build-arm64"
    draft="$out/$name-UNNOTARIZED.pkg"
    /bin/mkdir -p "$work/root" "$work/packages"
    /usr/bin/ditto --norsrc --noextattr --noacl "$app" "$work/root/NetUnstick.app"
    /bin/chmod -R u+w "$work/root"
    # A fixed location is essential for SMAppService. Atomically replace old bundles,
    # including files removed in this release; do not follow relocated test copies.
    /usr/bin/python3 - "$work/components.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump([{
        'RootRelativeBundlePath': 'NetUnstick.app',
        'BundleIsRelocatable': False,
        'BundleIsVersionChecked': True,
        'BundleHasStrictIdentifier': True,
        'BundleOverwriteAction': 'upgrade',
    }], stream)
PY
    /usr/bin/pkgbuild --root "$work/root" --component-plist "$work/components.plist" \
        --identifier org.netunstick.NetUnstick.pkg --version "$version.$build" \
        --install-location /Applications --ownership recommended "$work/packages/NetUnstick.pkg"
    /usr/bin/productbuild --distribution Distribution/Installer/Distribution.xml \
        --resources Distribution/Installer/Resources --package-path "$work/packages" \
        --identifier org.netunstick.NetUnstick.installer --version "$version.$build" \
        --sign "$installer_identity" --timestamp "$draft"
else
    draft="$resume"
    [[ -f "$draft" && "$draft" == *-UNNOTARIZED.pkg ]] || die 'Wznowienie wymaga istniejącego pliku *-UNNOTARIZED.pkg.'
    name="${draft:t}"
    name="${name%-UNNOTARIZED.pkg}"
    out="${draft:h}"
fi

# Verify the delivered payload, rather than just the build directory.
/usr/sbin/pkgutil --check-signature "$draft" | /usr/bin/tee "$out/$name-signature.txt"
/usr/bin/grep -Fq "1. $installer_name" "$out/$name-signature.txt" || die 'Pakiet nie jest podpisany oczekiwanym Developer ID Installer.'
/usr/sbin/pkgutil --expand-full "$draft" "$work/expanded"
payload="$work/expanded/NetUnstick.pkg/Payload/NetUnstick.app"
NetUnstick/TestSupport/check-helper-bundle.sh "$payload" --require-developer-id
/usr/bin/python3 - "$work/expanded" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
root = Path(sys.argv[1])
info = ET.parse(root / 'NetUnstick.pkg/PackageInfo').getroot()
assert info.attrib['identifier'] == 'org.netunstick.NetUnstick.pkg'
assert info.attrib['install-location'] == '/Applications'
bundle = info.find('bundle')
assert bundle is not None and bundle.attrib['path'] == './NetUnstick.app'
assert info.attrib['relocatable'] == 'false'
assert not info.findall('relocate/*'), 'Instalator nie może szukać przeniesionych kopii.'
assert not list(root.rglob('Scripts')), 'Instalator nie powinien uruchamiać skryptów.'
assert sorted(p.name for p in (root / 'NetUnstick.pkg/Payload').iterdir()) == ['NetUnstick.app']
dist = ET.parse(root / 'Distribution').getroot()
assert dist.find('options').attrib['hostArchitectures'] == 'arm64'
assert dist.find('volume-check/allowed-os-versions/os-version').attrib == {'min': '14.0'}
assert dist.find('domains').attrib == {
    'enable_anywhere': 'false', 'enable_currentUserHome': 'false', 'enable_localSystem': 'true'
}
assert info.find('scripts') is None
assert len(list(root.glob('*.pkg'))) == 1
print('Zweryfikowano: /Applications/NetUnstick.app z helperem, bez skryptów instalacyjnych.')
PY

if [[ "$prepare_only" == true ]]; then
    print "Pakiet roboczy (bez notaryzacji, nie do dystrybucji): $draft"
    exit 0
fi

result="$out/$name-notary.json"
if [[ -z "$submission_id" ]]; then
    /usr/bin/xcrun notarytool submit "$draft" --keychain-profile "$profile" --no-wait --output-format json > "$out/$name-submission.json"
    submission_id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$out/$name-submission.json")"
fi
print "Zgłoszenie Apple: $submission_id"
resume_suffix=''
if [[ "$update_feed" == true ]]; then resume_suffix=' --update-feed'; fi
print "Po przerwaniu wznów: Tools/BuildPKG.sh --resume '$draft' --submission-id '$submission_id' --notary-profile '$profile'$resume_suffix"
wait_code=0
/usr/bin/xcrun notarytool wait "$submission_id" --keychain-profile "$profile" --timeout 20m --output-format json > "$result" || wait_code=$?
if (( wait_code != 0 )); then
    /bin/cat "$result"
    die "Notaryzacja nie została potwierdzona (kod $wait_code). Zachowano pakiet roboczy i identyfikator; użyj podanej komendy wznowienia."
fi
/usr/bin/xcrun notarytool log "$submission_id" --keychain-profile "$profile" "$out/$name-notary-log.json"
/usr/bin/python3 - "$result" "$out/$name-notary-log.json" <<'PY'
import json, sys
result, log = (json.load(open(p)) for p in sys.argv[1:])
if result.get('status') != 'Accepted' or log.get('status') != 'Accepted':
    raise SystemExit('Apple nie zaakceptowało pakietu. Sprawdź zapisany log notaryzacji.')
issues = log.get('issues') or []
print('Uwagi Apple:', len(issues))
for issue in issues:
    print(issue.get('severity'), issue.get('message'))
PY

# Only publish the final filename after notarization, stapling and Gatekeeper pass.
candidate="$work/$name.pkg"
/bin/cp "$draft" "$candidate"
/usr/bin/xcrun stapler staple "$candidate"
/usr/bin/xcrun stapler validate "$candidate"
/usr/sbin/pkgutil --check-signature "$candidate"
/usr/sbin/spctl --assess --type install --verbose=2 "$candidate"
/usr/sbin/spctl --assess --type execute --verbose=2 "$payload"
final="$out/$name.pkg"
/bin/mv -f "$candidate" "$final"
(cd "$out" && /usr/bin/shasum -a 256 "$name.pkg" > "$name.pkg.sha256")
/bin/cat "$final.sha256"
print "Gotowy instalator Developer ID: $final"
if [[ "$update_feed" == true ]]; then
    Tools/BuildUpdateFeed.sh --package "$final"
fi
