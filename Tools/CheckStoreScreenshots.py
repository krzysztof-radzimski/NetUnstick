#!/usr/bin/env python3
"""Validate the local, localized Mac App Store screenshot set without uploading it."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = {
    "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "ga", "hr",
    "hu", "it", "lt", "lv", "mt", "nl", "pl", "pt", "ro", "sk", "sl", "sv",
}
ASC_LOCALIZATIONS = {
    "en-US": "en", "pl-PL": "pl", "es-ES": "es", "es-MX": "es", "cs": "cs",
    "da": "da", "de-DE": "de", "el": "el", "fi": "fi", "fr-FR": "fr",
    "hr": "hr", "hu": "hu", "it": "it", "nl-NL": "nl", "pt-PT": "pt",
    "ro": "ro", "sk": "sk", "sl": "sl", "sv": "sv",
}
SCENES = {"network-status": "01-network.jpg", "privacy-help": "02-privacy-help.jpg"}
IMAGE_PROPERTIES = {
    "pixelWidth": "2560", "pixelHeight": "1600", "format": "jpeg",
    "space": "RGB", "samplesPerPixel": "3", "hasAlpha": "no",
}
ASSET_PROPERTIES = {
    "width": 2560, "height": 1600, "format": "JPEG", "colorSpace": "RGB",
    "samplesPerPixel": 3, "hasAlpha": False,
}


class ValidationError(ValueError):
    """A screenshot or its manifest does not match the publication contract."""


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def read_image_properties(paths):
    """Use macOS ImageIO through sips; do not modify or re-encode any image."""
    command = ["/usr/bin/sips"]
    for key in IMAGE_PROPERTIES:
        command.extend(["-g", key])
    command.extend(str(path) for path in paths)
    result = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
    require(result.returncode == 0, "sips could not inspect the screenshot images")
    properties = {}
    current = None
    for line in result.stdout.splitlines():
        if line.startswith("/"):
            current = Path(line)
            properties[current] = {}
        elif current is not None and ":" in line:
            key, value = line.strip().split(":", 1)
            properties[current][key] = value.strip()
    require(set(properties) == set(paths), "sips did not inspect every expected image")
    return properties


def check(directory):
    directory = directory.resolve()
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    require(isinstance(manifest, dict), "manifest must be a JSON object")
    require(manifest.get("schemaVersion") == 1, "unsupported manifest schemaVersion")
    app = manifest.get("app", {})
    require(isinstance(app, dict), "manifest app must be an object")
    require(app.get("bundleIdentifier") == "org.netunstick.NetUnstick.AppStore",
            "manifest must identify the Mac App Store app")
    require(bool(app.get("version")) and bool(app.get("build")), "app version and build are required")

    upload = manifest.get("upload", {})
    require(isinstance(upload, dict), "manifest upload must be an object")
    require(upload.get("localizations") == ASC_LOCALIZATIONS,
            "expected all 19 App Store Connect mappings, including es-ES and es-MX to es")
    local_only = LANGUAGES - set(ASC_LOCALIZATIONS.values())
    listed_local_only = upload.get("localOnlyLanguages", [])
    require(isinstance(listed_local_only, list) and len(listed_local_only) == len(local_only)
            and set(listed_local_only) == local_only, "incorrect local-only language list")

    languages = manifest.get("languages", [])
    require(isinstance(languages, list) and len(languages) == len(LANGUAGES),
            "manifest must contain exactly 24 languages")
    require(all(isinstance(language, dict) for language in languages),
            "each language entry must be an object")
    codes = [language.get("language") for language in languages]
    require(all(isinstance(code, str) for code in codes) and set(codes) == LANGUAGES,
            "manifest language codes must be unique and cover all 24 languages")
    expected_paths = {f"{code}/{filename}" for code in LANGUAGES for filename in SCENES.values()}
    actual_paths = {
        str(path.relative_to(directory)) for path in directory.rglob("*")
        if path.is_file() and path.suffix.lower() in {".jpg", ".jpeg", ".png", ".heic", ".tif", ".tiff", ".webp"}
    }
    require(actual_paths == expected_paths,
            f"image files differ from the required 48: missing={sorted(expected_paths - actual_paths)}, "
            f"unexpected={sorted(actual_paths - expected_paths)}")

    paths = []
    hashes = []
    total_bytes = 0
    for language in languages:
        code = language["language"]
        expected_locales = {locale for locale, native in ASC_LOCALIZATIONS.items() if native == code}
        locales = language.get("appStoreConnectLocalizations", [])
        require(isinstance(locales, list) and len(locales) == len(expected_locales)
                and set(locales) == expected_locales, f"{code}: incorrect App Store Connect locales")
        require(language.get("localOnly") is (code in local_only), f"{code}: incorrect localOnly flag")
        assets = language.get("assets", [])
        require(isinstance(assets, list) and len(assets) == 2
                and all(isinstance(asset, dict) for asset in assets), f"{code}: expected two assets")
        require({asset.get("scene") for asset in assets} == set(SCENES), f"{code}: missing or duplicate scene")
        for asset in assets:
            relative = f"{code}/{SCENES[asset['scene']]}"
            require(asset.get("path") == relative, f"{code}: unexpected asset path")
            path = directory / relative
            require(not path.is_symlink() and not path.parent.is_symlink(), f"{relative}: symbolic links are not allowed")
            for key, value in ASSET_PROPERTIES.items():
                require(type(asset.get(key)) is type(value) and asset.get(key) == value,
                        f"{relative}: invalid manifest property {key}")
            size = path.stat().st_size
            require(asset.get("bytes") == size and size > 0, f"{relative}: file size mismatch")
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            require(asset.get("sha256") == digest, f"{relative}: SHA-256 mismatch")
            paths.append(path)
            hashes.append(digest)
            total_bytes += size
    require(len(set(hashes)) == 48, "screenshots must be distinct; duplicate image bytes found")
    properties = read_image_properties(paths)
    for path, values in properties.items():
        require(values == IMAGE_PROPERTIES,
                f"{path.relative_to(directory)}: expected JPEG 2560x1600 RGB, three samples and no alpha; got {values}")
    return {
        "valid": True, "appVersion": str(app["version"]), "build": str(app["build"]),
        "languages": 24, "images": 48, "assetsPerLanguage": 2,
        "appStoreConnectLocalizations": 19, "mappedNativeLanguages": 18,
        "localOnlyLanguages": sorted(local_only), "dimensions": "2560x1600",
        "format": "JPEG", "colorSpace": "RGB", "hasAlpha": False,
        "sha256Verified": True, "totalBytes": total_bytes,
        "uploadStatusChecked": False,
        "note": "Local file validation does not verify upload, visual content or capture provenance.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path,
                        default=ROOT / "Distribution/AppStore/Screenshots",
                        help="Directory containing manifest.json and the 24 language folders")
    args = parser.parse_args()
    try:
        result = check(args.directory)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        print(json.dumps({"valid": False, "error": str(error)}, ensure_ascii=False, indent=2))
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
