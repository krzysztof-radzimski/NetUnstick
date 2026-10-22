#!/usr/bin/env python3
"""Validate prepared metadata; --submission rejects unresolved publication fields."""
import argparse
import html
import json
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, HTTPRedirectHandler, build_opener
from urllib.error import HTTPError, URLError

ROOT = Path(__file__).resolve().parents[1]


class HTTPSRedirectHandler(HTTPRedirectHandler):
    # System Python on some macOS versions predates urllib's support for HTTP 308.
    http_error_308 = HTTPRedirectHandler.http_error_301

    def redirect_request(self, request, fp, code, message, headers, new_url):
        if urlparse(new_url).scheme != "https":
            raise URLError("redirected away from HTTPS")
        if code == 308 and request.get_method() in ("GET", "HEAD"):
            return Request(new_url, headers=request.headers, method=request.get_method())
        return super().redirect_request(request, fp, code, message, headers, new_url)


class PublicPage(HTMLParser):
    """Read public content including Cloudflare's browser-decoded contact links."""
    def __init__(self, body):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.feed(body)

    def handle_data(self, data):
        self.parts.append(data)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.parts.append(html.unescape(attrs.get("href", "")))
        encoded = attrs.get("data-cfemail", "")
        if 4 <= len(encoded) <= 512:
            try:
                raw = bytes.fromhex(encoded)
                self.parts.append(bytes(value ^ raw[0] for value in raw[1:]).decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                pass

    @property
    def text(self):
        return " ".join(self.parts)


def check(submission=False, check_urls=False):
    blockers = []
    checked_urls = {}
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
            elif check_urls:
                address = data[field]
                if address not in checked_urls:
                    try:
                        request = Request(address, headers={"User-Agent": "NetUnstick-Publication-Check/1.0"})
                        with build_opener(HTTPSRedirectHandler()).open(request, timeout=10) as response:
                            assert urlparse(response.url).scheme == "https", "redirected away from HTTPS"
                            assert response.status == 200, f"HTTP {response.status}"
                            assert "text/html" in response.headers.get("Content-Type", ""), "expected HTML"
                            body = response.read(512 * 1024).decode("utf-8", errors="replace")
                            page = PublicPage(body).text
                            assert "NetUnstick" in page, "page does not identify NetUnstick"
                            assert "kr@itorg.pl" in page, "support contact absent"
                        checked_urls[address] = None
                    except (AssertionError, HTTPError, URLError, OSError) as error:
                        checked_urls[address] = str(error)
                if checked_urls[address]:
                    blockers.append(f"{path.name}: {field}: {checked_urls[address]}")
    result = {"metadataLocales": len(files), "textLimitsValid": True,
              "publicationFieldsComplete": not blockers, "publicURLsChecked": check_urls,
              "blockers": blockers,
              "note": "Account agreements, profiles, screenshots, language review and Apple review remain separate checks."}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if submission and blockers:
        raise SystemExit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--submission", action="store_true")
    parser.add_argument("--check-urls", action="store_true", help="Verify public HTTPS content, not only URL format")
    args = parser.parse_args()
    check(args.submission, args.check_urls or args.submission)
