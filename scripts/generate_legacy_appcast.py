#!/usr/bin/env python3
"""Keep StatusBox's feed informational after loss of its EdDSA signing key."""
import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def make_feed(version: str, build: str, repository: str, tag: str) -> ET.ElementTree:
    ET.register_namespace("sparkle", SPARKLE)
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "StatusBox → MenuBox"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"MenuBox {version} — one-time installation required"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "13.0"
    ET.SubElement(item, "link").text = f"https://github.com/{repository}/releases/tag/{tag}"
    # No enclosure: Sparkle opens the release page instead of trying an untrusted update.
    ET.SubElement(item, "description").text = (
        "<h2>StatusBox is now MenuBox</h2>"
        "<p>This upgrade requires a one-time installation from the release page or Homebrew. "
        "The previous update signing key is no longer available, so StatusBox cannot "
        "securely install this release automatically.</p>"
        "<p>Quit StatusBox, install MenuBox, then launch MenuBox. Saved settings are imported. "
        "Re-enable required permissions and Launch at Login for MenuBox, and remove the old "
        "StatusBox app/login item after confirming the migration.</p>"
        "<p>Homebrew users: <code>brew update &amp;&amp; brew upgrade --cask elixirevo/tap/menubox</code>.</p>"
        "<p>MenuBox 1.2 and later use a new signed update feed for future in-app updates.</p>"
        "<p>기존 StatusBox 사용자는 이번 한 번 MenuBox를 직접 설치하거나 Homebrew로 업데이트해야 합니다. "
        "설정은 이전되며, MenuBox의 권한과 로그인 시 실행 설정을 다시 확인해 주세요.</p>"
    )
    ET.indent(root)
    return ET.ElementTree(root)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("version", "build", "repository", "tag"):
        parser.add_argument(f"--{name}", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    make_feed(args.version, args.build, args.repository, args.tag).write(
        args.output, encoding="utf-8", xml_declaration=True
    )
