#!/bin/zsh
set -euo pipefail
bundle="$1"
signing_mode="${2:-}"
[[ -z "$signing_mode" || "$signing_mode" == '--require-stable-signing' ]]
helper="$bundle/Contents/MacOS/NetUnstickHelper"
plist="$bundle/Contents/Library/LaunchDaemons/org.netunstick.NetUnstick.helper.plist"
test -x "$helper"
plutil -lint "$plist" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$plist")" == 'Contents/MacOS/NetUnstickHelper' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist")" == 'org.netunstick.NetUnstick.helper' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:org.netunstick.NetUnstick.helper' "$plist")" == 'true' ]]
file "$helper" | grep -q 'Mach-O 64-bit executable arm64'
# The app and daemon must not depend on package frameworks outside the bundle.
! otool -L "$bundle/Contents/MacOS/NetUnstick" | grep -q 'PackageProduct.framework'
! otool -L "$helper" | grep -q 'PackageProduct.framework'
# Source contract ties the listener to a fixed app identifier and the helper's certificate.
grep -q 'setCodeSigningRequirement(requirement)' NetUnstickHelper/main.swift
grep -q 'certificate leaf = H' Packages/NetUnstickKit/Sources/NetUnstickRepair/Privileged/ClientIdentityPolicy.swift

if [[ "$signing_mode" == '--require-stable-signing' ]]; then
  app_requirement="$(codesign -dr - "$bundle" 2>&1)"
  helper_requirement="$(codesign -dr - "$helper" 2>&1)"
  app_certificate="$(print -r -- "$app_requirement" | sed -nE 's/.*certificate (root|leaf) = H"([[:xdigit:]]{40})".*/\2/p')"
  helper_certificate="$(print -r -- "$helper_requirement" | sed -nE 's/.*certificate (root|leaf) = H"([[:xdigit:]]{40})".*/\2/p')"
  [[ -n "$app_certificate" && "$app_certificate" == "$helper_certificate" ]]
  [[ "$app_requirement" == *'identifier "org.netunstick.NetUnstick"'* ]]
  [[ "$helper_requirement" == *'identifier NetUnstickHelper'* ]]
  codesign --verify --strict "$helper"
  codesign --verify --deep --strict "$bundle"
  app_client_requirement="identifier \"org.netunstick.NetUnstick\" and certificate leaf = H\"$app_certificate\""
  codesign --verify --strict "-R=$app_client_requirement" "$bundle"
  if codesign --verify "-R=$app_client_requirement" "$helper" >/dev/null 2>&1; then
    print -u2 'Helper błędnie spełnia wymaganie podpisu klienta XPC.'
    exit 1
  fi
fi
printf 'helper bundle and listener requirement: ok\n' 
