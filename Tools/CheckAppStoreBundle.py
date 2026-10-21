#!/usr/bin/env python3
"""Validate a built sandbox edition; not an App Review approval or signing service."""
import argparse
import json
import plistlib
import subprocess
import sys
from pathlib import Path


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def validate(app: Path, distribution: bool):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "org.netunstick.NetUnstick.AppStore", "Wrong distribution bundle ID"
    minimum = tuple(int(value) for value in info["LSMinimumSystemVersion"].split(".")[:2])
    assert minimum >= (14, 0), "Unexpected deployment target"
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    assert executable.is_file(), "Missing main executable"
    assert not (app / "Contents/Library/LaunchDaemons").exists(), "Root LaunchDaemons must not ship"
    assert not any("helper" in p.name.lower() for p in (app / "Contents").rglob("*")), "Helper found in Store bundle"
    assert list((app / "Contents/MacOS").iterdir()) == [executable], "Unexpected executable payload"
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    entitlements = plistlib.loads(run("/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)))
    required = {"com.apple.security.app-sandbox", "com.apple.security.network.client",
                "com.apple.security.network.server", "com.apple.security.files.user-selected.read-write"}
    assert all(entitlements.get(key) is True for key in required), "Missing sandbox capability"
    allowed = required | {"com.apple.security.get-task-allow", "com.apple.application-identifier",
                          "com.apple.developer.team-identifier"}
    assert not set(entitlements) - allowed, f"Unexpected entitlements: {set(entitlements) - allowed}"
    symbols = run("/usr/bin/nm", "-u", str(executable)).decode("utf-8", errors="replace")
    forbidden_symbols = ["_posix_spawn", "_execve", "_system", "_OBJC_CLASS_$_NSTask", "_OBJC_CLASS_$_SMAppService"]
    imported_symbols = {line.split()[-1] for line in symbols.splitlines() if line.split()}
    assert not imported_symbols.intersection(forbidden_symbols), "Subprocess or privilege API in Store binary"
    payload = executable.read_bytes()
    command_paths = [b"/usr/bin/dscl", b"/usr/bin/smbutil", b"/usr/sbin/netstat", b"/usr/sbin/scutil",
                     b"/usr/sbin/sharing", b"/usr/libexec/ApplicationFirewall/socketfilterfw", b"/sbin/route"]
    assert not any(path in payload for path in command_paths), "System command payload in Store binary"
    manifest = plistlib.loads((app / "Contents/Resources/PrivacyInfo.xcprivacy").read_bytes())
    assert manifest.get("NSPrivacyTracking") is False, "Tracking declaration inconsistent"
    assert not manifest.get("NSPrivacyCollectedDataTypes"), "Review privacy labels before adding collected data"
    assert (app / "Contents/Resources/en.lproj").is_dir(), "English resources absent"
    assert (app / "Contents/Resources/pl.lproj").is_dir(), "Polish resources absent"
    if distribution:
        details = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)],
                                 check=True, capture_output=True, text=True).stderr
        assert "TeamIdentifier=UGL4ZTH3C6" in details, "Unexpected signing team"
        assert "Authority=Apple Distribution:" in details or "Authority=3rd Party Mac Developer Application:" in details, "App Store distribution certificate required"
        assert not entitlements.get("com.apple.security.get-task-allow"), "Debug entitlement in distribution bundle"
        assert (app / "Contents/embedded.provisionprofile").is_file(), "Store distribution provisioning profile absent"
    print(json.dumps({"bundle": app.name, "sandbox": True, "helper": False,
                      "subprocessImports": False, "distributionSignatureChecked": distribution}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--distribution", action="store_true")
    args = parser.parse_args()
    try:
        validate(args.app, args.distribution)
    except (AssertionError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Store bundle check failed: {error}", file=sys.stderr)
        sys.exit(1)
