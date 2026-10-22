#!/bin/zsh
set -euo pipefail

# Creates a local archive only. It never exports, uploads or changes a Developer ID installation.
# The optional flag explicitly permits Xcode to update this app's signing assets using its account.
project_root="${0:A:h:h}"
signing_options=()
if [[ "${1:-}" == --allow-provisioning-updates ]]; then
  signing_options=(-allowProvisioningUpdates)
  shift
fi
if (( $# > 1 )); then
  print -u2 'Użycie: ArchiveAppStore.sh [--allow-provisioning-updates] [ścieżka-archiwum]'
  exit 2
fi
archive_path="${1:-$project_root/Artifacts/Distribution/NetUnstickAppStore.xcarchive}"

/usr/bin/xcodebuild \
  -project "$project_root/NetUnstick.xcodeproj" \
  -scheme NetUnstickAppStore \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  "${signing_options[@]}" \
  archive

/usr/bin/python3 "$project_root/Tools/CheckAppStoreBundle.py" \
  "$archive_path/Products/Applications/NetUnstick App Store.app"
print "Archiwum lokalne: $archive_path"
print 'Podpis Apple Development archiwum nie jest podpisem dystrybucyjnym. Eksport App Store podpisuje Xcode/Organizer.'
print 'Gotowy eksport sprawdź CheckAppStoreBundle.py --distribution; dla TestFlight dodaj --testflight.'
print 'Profil macOS jest wymagany dla TestFlight i ograniczonych uprawnień; ten skrypt niczego nie wysyła.'
