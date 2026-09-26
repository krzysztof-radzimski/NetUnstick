#!/bin/zsh
set -euo pipefail
bundle="$1"
helper="$bundle/Contents/MacOS/NetUnstickHelper"
plist="$bundle/Contents/Library/LaunchDaemons/org.netunstick.NetUnstick.helper.plist"
test -x "$helper"
plutil -lint "$plist" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$plist")" == 'Contents/MacOS/NetUnstickHelper' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist")" == 'org.netunstick.NetUnstick.helper' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:org.netunstick.NetUnstick.helper' "$plist")" == 'true' ]]
file "$helper" | grep -q 'Mach-O 64-bit executable arm64'
# Source contract ties the listener to a Team ID and a fixed app identifier.
grep -q 'setCodeSigningRequirement(requirement)' NetUnstickHelper/main.swift
grep -q 'anchor apple generic' Packages/NetUnstickKit/Sources/NetUnstickRepair/Privileged/ClientIdentityPolicy.swift
# A release artifact must use the same Apple Team ID for the app and helper.
helper_team="$(codesign -dv "$helper" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ -n "$helper_team" && "$helper_team" != 'not set' ]]; then
  app_team="$(codesign -dv "$bundle" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "$app_team" == "$helper_team" ]]
  codesign --verify --strict "$helper"
  codesign --verify --strict "$bundle"
fi
printf 'helper bundle and listener requirement: ok\n' 
