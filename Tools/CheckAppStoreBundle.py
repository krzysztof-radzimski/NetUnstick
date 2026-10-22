#!/usr/bin/env python3
"""Validate a built sandbox edition; not an App Review approval or signing service."""
import argparse
import datetime
import fnmatch
import json
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

TEAM = "UGL4ZTH3C6"
BUNDLE_ID = "org.netunstick.NetUnstick.AppStore"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def requires_profile(entitlements, testflight=False):
    """macOS sandbox/hardened-runtime entitlements are unrestricted (Apple TN3125)."""
    return testflight or any(
        not key.startswith("com.apple.security.")
        and key not in {"com.apple.application-identifier", "application-identifier",
                        "com.apple.developer.team-identifier"}
        for key in entitlements
    )


def allows_claim(allowed, claim):
    if isinstance(claim, str) and isinstance(allowed, str):
        return fnmatch.fnmatchcase(claim, allowed)
    if isinstance(claim, list) and isinstance(allowed, list):
        return all(any(allows_claim(candidate, value) for candidate in allowed) for value in claim)
    return type(claim) is type(allowed) and claim == allowed


def validate_profile_payload(profile, entitlements, certificate, distribution, now=None):
    """Check the decoded profile against this app, signer and requested capabilities."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, datetime.datetime), "Provisioning profile has no expiration date")
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=datetime.timezone.utc)
    require(expiry > now, "Provisioning profile has expired")
    require(bool(set(profile.get("Platform", [])) & {"OSX", "macOS"}), "Provisioning profile is not for macOS")
    require(profile.get("TeamIdentifier") == [TEAM], "Provisioning profile belongs to another team")
    claims = profile.get("Entitlements", {})
    app_id = claims.get("com.apple.application-identifier", claims.get("application-identifier"))
    require(app_id == f"{TEAM}.{BUNDLE_ID}", "Provisioning profile does not match the explicit App ID")
    require(certificate in profile.get("DeveloperCertificates", []), "Provisioning profile does not include this signing certificate")
    for key, value in entitlements.items():
        if key.startswith("com.apple.security.") or key in {
                "com.apple.application-identifier", "application-identifier",
                "com.apple.developer.team-identifier"}:
            continue
        require(key in claims and allows_claim(claims[key], value),
                "Provisioning profile does not authorize a requested restricted entitlement")
    if distribution:
        require(not profile.get("ProvisionedDevices"), "Development or ad hoc profile in distribution bundle")
        require(not profile.get("ProvisionsAllDevices"), "Non-App-Store profile in distribution bundle")
        require(not claims.get("get-task-allow") and not claims.get("com.apple.security.get-task-allow"),
                "Development provisioning profile in distribution bundle")


def validate(app: Path, distribution=False, testflight=False):
    distribution = distribution or testflight
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == BUNDLE_ID, "Wrong distribution bundle ID")
    minimum = tuple(int(value) for value in info["LSMinimumSystemVersion"].split(".")[:2])
    require(minimum >= (14, 0), "Unexpected deployment target")
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    require(executable.is_file(), "Missing main executable")
    require(not (app / "Contents/Library/LaunchDaemons").exists(), "Root LaunchDaemons must not ship")
    require(not any("helper" in p.name.lower() for p in (app / "Contents").rglob("*")), "Helper found in Store bundle")
    require(list((app / "Contents/MacOS").iterdir()) == [executable], "Unexpected executable payload")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    entitlements = plistlib.loads(run("/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)))
    required = {"com.apple.security.app-sandbox", "com.apple.security.network.client",
                "com.apple.security.network.server", "com.apple.security.files.user-selected.read-write"}
    require(all(entitlements.get(key) is True for key in required), "Missing sandbox capability")
    allowed = required | {"com.apple.security.get-task-allow", "com.apple.application-identifier",
                          "application-identifier", "com.apple.developer.team-identifier", "beta-reports-active"}
    require(not set(entitlements) - allowed, "Unexpected entitlements: review Store capabilities before distribution")
    for key in {"com.apple.application-identifier", "application-identifier"}:
        if key in entitlements:
            require(entitlements[key] == f"{TEAM}.{BUNDLE_ID}", "Signing App ID does not match this app")
    if "com.apple.developer.team-identifier" in entitlements:
        require(entitlements["com.apple.developer.team-identifier"] == TEAM, "Wrong entitlement signing team")
    symbols = run("/usr/bin/nm", "-u", str(executable)).decode("utf-8", errors="replace")
    forbidden_symbols = {"_posix_spawn", "_execve", "_system", "_OBJC_CLASS_$_NSTask", "_OBJC_CLASS_$_SMAppService"}
    imported_symbols = {line.split()[-1] for line in symbols.splitlines() if line.split()}
    require(not imported_symbols.intersection(forbidden_symbols), "Subprocess or privilege API in Store binary")
    payload = executable.read_bytes()
    command_paths = [b"/usr/bin/dscl", b"/usr/bin/smbutil", b"/usr/sbin/netstat", b"/usr/sbin/scutil",
                     b"/usr/sbin/sharing", b"/usr/libexec/ApplicationFirewall/socketfilterfw", b"/sbin/route"]
    require(not any(path in payload for path in command_paths), "System command payload in Store binary")
    manifest = plistlib.loads((app / "Contents/Resources/PrivacyInfo.xcprivacy").read_bytes())
    require(manifest.get("NSPrivacyTracking") is False, "Tracking declaration inconsistent")
    require(not manifest.get("NSPrivacyCollectedDataTypes"), "Review privacy labels before adding collected data")
    require((app / "Contents/Resources/en.lproj").is_dir(), "English resources absent")
    require((app / "Contents/Resources/pl.lproj").is_dir(), "Polish resources absent")
    if distribution:
        details = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)],
                                 check=True, capture_output=True, text=True).stderr
        require(f"TeamIdentifier={TEAM}" in details, "Unexpected signing team")
        require("Authority=Apple Distribution:" in details or "Authority=3rd Party Mac Developer Application:" in details,
                "App Store distribution certificate required; archive signing alone is not distribution signing")
        run("/usr/bin/codesign", "--verify", "--strict", "-R",
            f'=anchor apple generic and certificate leaf[subject.OU] = "{TEAM}"', str(app))
        require(not entitlements.get("com.apple.security.get-task-allow"), "Debug entitlement in distribution bundle")
    profile = app / "Contents/embedded.provisionprofile"
    profile_required = requires_profile(entitlements, testflight)
    require(profile.is_file() or not profile_required,
            "Provisioning profile required for TestFlight or restricted entitlements")
    if profile.is_file():
        decoded = plistlib.loads(run("/usr/bin/security", "cms", "-D", "-i", str(profile)))
        with tempfile.TemporaryDirectory(prefix="netunstick-public-signer-") as directory:
            prefix = str(Path(directory) / "certificate")
            run("/usr/bin/codesign", "-d", f"--extract-certificates={prefix}", str(app))
            certificate = Path(prefix + "0").read_bytes()
        validate_profile_payload(decoded, entitlements, certificate, distribution)
    print(json.dumps({"bundle": app.name, "sandbox": True, "helper": False,
                      "subprocessImports": False, "distributionSignatureChecked": distribution,
                      "provisioningProfileRequired": profile_required,
                      "provisioningProfileValidated": profile.is_file()}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--distribution", action="store_true", help="Require App Store distribution signing")
    parser.add_argument("--testflight", action="store_true", help="Also require an embedded provisioning profile")
    args = parser.parse_args()
    try:
        validate(args.app, args.distribution, args.testflight)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Store bundle check failed: {error}", file=sys.stderr)
        sys.exit(1)
