#!/usr/bin/env python3
"""Build offline static policy/support pages for hosting; never publishes or uploads."""
import html
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = json.loads((ROOT / "Tools/LocalizationSource.json").read_text())["strings"]


def build():
    output = ROOT / "Distribution/Website"
    for language in ("en", "pl"):
        for page, title, sections in (
            ("privacy", "help_privacy", ["privacy_local", "privacy_network", "privacy_retention", "privacy_permissions", "privacy_version"]),
            ("support", "help_support", ["help_start", "help_editions", "help_support", "help_safety"]),
        ):
            def text(key):
                return html.escape(SOURCE[key][language])
            content = "\n".join(f"<section><h2>{text(key + '_title')}</h2><p>{text(key + '_body')}</p></section>" for key in sections)
            document = f'''<!doctype html>
<html lang="{language}"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>NetUnstick — {text(title)}</title>
<style>:root{{color-scheme:light dark}}body{{font:1.05rem/1.6 system-ui;margin:3rem auto;padding:0 1.5rem;max-width:48rem}}a{{color:inherit}}h1,h2{{line-height:1.25}}</style>
<main><h1>NetUnstick — {text(title)}</h1>{content}</main>
</html>
'''
            path = output / language / f"{page}.html"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(document)
    print("Prepared 4 static pages in Distribution/Website; no publication performed.")


if __name__ == "__main__":
    build()
