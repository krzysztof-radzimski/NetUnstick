#!/usr/bin/env python3
"""Validate prepared metadata; --submission rejects unresolved publication fields."""
import argparse
import json
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]


def check(submission=False):
    blockers = []
    files = sorted((ROOT / "Distribution/AppStore").glob("metadata.*.json"))
    assert files, "No metadata files"
    for path in files:
        data = json.loads(path.read_text())
        assert data["bundleId"] == "org.netunstick.NetUnstick.AppStore", path
        assert len(data["name"]) <= 30 and len(data["subtitle"]) <= 30, path
        assert len(data["promotionalText"]) <= 170, path
        assert len(data["description"]) <= 4000, path
        assert len(data["keywords"].encode("utf-8")) <= 100, path
        assert len(data["reviewNotes"].encode("utf-8")) <= 4000, path
        for field in ("supportURL", "privacyPolicyURL"):
            url = urlparse(data.get(field) or "")
            if url.scheme != "https" or not url.hostname or url.hostname in {"localhost", "example.com"}:
                blockers.append(f"{path.name}: {field} requires a published HTTPS page")
    result = {"metadataLocales": len(files), "textLimitsValid": True,
              "publicationFieldsComplete": not blockers, "blockers": blockers,
              "note": "Account agreements, profiles, screenshots, language review and Apple review remain separate checks."}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if submission and blockers:
        raise SystemExit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--submission", action="store_true")
    check(parser.parse_args().submission)
