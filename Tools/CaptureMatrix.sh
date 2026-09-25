#!/bin/zsh
set -euo pipefail
app="DerivedData/Build/Products/Debug/NetUnstick.app/Contents/MacOS/NetUnstick"
mkdir -p Artifacts/ScreenshotMatrix
for scenario in healthy dns-residue vpn-unknown operation-progress; do
  for variant in light dark contrast; do
    args=("--scenario=$scenario")
    if [[ "$variant" == light ]]; then args+=(--ui-light); fi
    if [[ "$variant" == dark ]]; then args+=(--ui-dark); fi
    if [[ "$variant" == contrast ]]; then args+=(--ui-light --ui-contrast); fi
    open -n ./DerivedData/Build/Products/Debug/NetUnstick.app --args "${args[@]}"
    child=$(pgrep -nx NetUnstick)
    window=""
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      sleep 1
      window=$(swift -e 'import CoreGraphics; let p = Int(CommandLine.arguments[1])!; let a = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as! [[String:Any]]; for w in a where (w[kCGWindowOwnerPID as String] as? Int) == p { if let n = w[kCGWindowNumber as String] as? Int { print(n); break } }' "$child")
      [[ -n "$window" ]] && break
    done
    if [[ -z "$window" ]]; then kill "$child" 2>/dev/null || true; echo "No window: $scenario $variant" >&2; exit 1; fi
    screencapture -x -l "$window" "Artifacts/ScreenshotMatrix/$scenario-$variant.png"
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  done
done
