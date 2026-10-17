#!/bin/zsh
set -euo pipefail
bundle="$1"
signing_mode="${2:-}"
[[ -z "$signing_mode" || "$signing_mode" == '--require-stable-signing' || "$signing_mode" == '--require-developer-id' ]]
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

if [[ -n "$signing_mode" ]]; then
  codesign --verify --strict "$helper"
  codesign --verify --deep --strict "$bundle"
  app_requirement="$(codesign -dr - "$bundle" 2>&1)"
  helper_requirement="$(codesign -dr - "$helper" 2>&1)"
  [[ "$app_requirement" != *cdhash* && "$helper_requirement" != *cdhash* ]]
  # Developer ID uses an Apple anchor and Team ID in its designated requirement,
  # rather than embedding a certificate fingerprint. Read the real leaf certificates,
  # exactly as the daemon does; these DER files contain public certificates only.
  signing_work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/netunstick-signing-check.XXXXXX")"
  trap '/bin/rm -rf -- "$signing_work"' EXIT INT TERM
  codesign -d "--extract-certificates=$signing_work/app-cert-" "$bundle"
  codesign -d "--extract-certificates=$signing_work/helper-cert-" "$helper"
  app_certificate="$(/usr/bin/shasum -a 1 "$signing_work/app-cert-0" | /usr/bin/awk '{print $1}')"
  helper_certificate="$(/usr/bin/shasum -a 1 "$signing_work/helper-cert-0" | /usr/bin/awk '{print $1}')"
  [[ -n "$app_certificate" && "$app_certificate" == "$helper_certificate" ]]
  [[ "$app_requirement" == *'identifier "org.netunstick.NetUnstick"'* ]]
  [[ "$helper_requirement" == *'identifier NetUnstickHelper'* ]]
  app_client_requirement="identifier \"org.netunstick.NetUnstick\" and certificate leaf = H\"$app_certificate\""
  codesign --verify --strict "-R=$app_client_requirement" "$bundle"
  if codesign --verify "-R=$app_client_requirement" "$helper" >/dev/null 2>&1; then
    print -u2 'Helper błędnie spełnia wymaganie podpisu klienta XPC.'
    exit 1
  fi
  if [[ "$signing_mode" == '--require-developer-id' ]]; then
    developer_requirement='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "UGL4ZTH3C6"'
    for code_object in "$bundle" "$helper"; do
      codesign --verify --strict "-R=$developer_requirement" "$code_object"
      details="$(codesign -dvvv "$code_object" 2>&1)"
      print -r -- "$details" | /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)'
      print -r -- "$details" | /usr/bin/grep -q '^Timestamp='
      entitlements="$(codesign -d --entitlements - --xml "$code_object" 2>/dev/null)"
      get_task_allow='false'
      if [[ -n "$entitlements" ]]; then
        get_task_allow="$(print -r -- "$entitlements" | /usr/bin/python3 -c 'import plistlib, sys; print(str(plistlib.loads(sys.stdin.buffer.read()).get("com.apple.security.get-task-allow", False)).lower())')"
      fi
      if [[ "$get_task_allow" != 'false' ]]; then
        print -u2 "Niedozwolone get-task-allow w wydaniu: $code_object"
        exit 1
      fi
    done
  fi
fi
printf 'helper bundle and listener requirement: ok\n' 
