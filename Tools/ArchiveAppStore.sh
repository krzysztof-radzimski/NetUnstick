#!/bin/zsh
set -euo pipefail

# Creates a local archive only. It never uploads, changes a Developer ID installation,
# retrieves account credentials or silently creates App Store Connect records.
project_root="${0:A:h:h}"
archive_path="${1:-$project_root/Artifacts/Distribution/NetUnstickAppStore.xcarchive}"

/usr/bin/xcodebuild \
  -project "$project_root/NetUnstick.xcodeproj" \
  -scheme NetUnstickAppStore \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  archive

/usr/bin/python3 "$project_root/Tools/CheckAppStoreBundle.py" \
  "$archive_path/Products/Applications/NetUnstick App Store.app" --distribution
print "Archiwum lokalne: $archive_path"
print 'Dystrybucję do App Store Connect wykonaj po sprawdzeniu metadanych, profilu i raportu prywatności w Organizerze.'
