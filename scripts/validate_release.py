#!/usr/bin/env python3
"""Validate architecture routing, signatures, and legacy migration before publishing."""
import argparse
import hashlib
import plistlib
import re
from pathlib import Path
import subprocess
from urllib.parse import urlparse
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
NS = {"s": SPARKLE}


def validate_bundle(dmg: Path, arch: str, build: int, expected: dict) -> None:
    mounted = plistlib.loads(subprocess.check_output([
        "hdiutil", "attach", "-readonly", "-nobrowse", "-plist", str(dmg)
    ]))
    mount = next(Path(e["mount-point"]) for e in mounted["system-entities"] if "mount-point" in e)
    try:
        app = mount / "MenuBox.app"
        actual = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleName", "CFBundleShortVersionString",
                    "SUFeedURL", "SUPublicEDKey", "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"):
            assert actual[key] == expected[key], f"Bundled {key} differs from source"
        assert int(actual["CFBundleVersion"]) == build
        slices = subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS/MenuBox")], text=True).strip()
        assert slices == arch, f"Wrong executable architecture: {slices}"
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        subprocess.run(["xcrun", "stapler", "validate", str(app)], check=True)
        subprocess.run(["spctl", "--assess", "--type", "execute", str(app)], check=True)
    finally:
        subprocess.run(["hdiutil", "detach", str(mount)], check=True)


def validate(dist: Path, version: str, account: str, repository: str, tag: str) -> None:
    root = Path(__file__).resolve().parent.parent
    plist = plistlib.loads((root / "Resources/Info.plist").read_bytes())
    assert plist["CFBundleShortVersionString"] == version
    assert plist["CFBundleIdentifier"] == "com.elixirevo.MenuBox"
    assert plist["SUFeedURL"] == f"https://github.com/{repository}/releases/latest/download/menubox-appcast.xml"
    assert plist["SURequireSignedFeed"] and plist["SUVerifyUpdateBeforeExtraction"]
    assert plist["SUPublicEDKey"] == (root / "sparkle-public-key.txt").read_text().strip()
    tools = root / ".build/artifacts/sparkle/Sparkle/bin"
    key = subprocess.check_output([str(tools / "generate_keys"), "--account", account, "-p"], text=True).strip()
    assert key == plist["SUPublicEDKey"], "Wrong Sparkle signing key"
    feed = dist / f"appcast-{version}/menubox-appcast.xml"
    subprocess.run([str(tools / "sign_update"), "--account", account, "--verify", str(feed)], check=True)
    items = ET.parse(feed).findall("channel/item")
    assert len(items) == 2, "Both architectures must be offered"
    builds = {}
    checksums = []
    cask = (root / "homebrew/Casks/menubox.rb").read_text()
    assert f'version "{version}"' in cask
    for item in items:
        enclosure = item.find("enclosure")
        assert enclosure is not None
        url = enclosure.attrib["url"]
        assert url.startswith(f"https://github.com/{repository}/releases/download/{tag}/")
        name = Path(urlparse(url).path).name
        arch = next(a for a in ("arm64", "x86_64") if name == f"MenuBox-{version}-{a}.dmg")
        assert arch not in builds
        dmg = dist / name
        assert int(enclosure.attrib["length"]) == dmg.stat().st_size
        assert item.findtext("s:shortVersionString", namespaces=NS) == version
        assert item.findtext("s:minimumSystemVersion", namespaces=NS) == "13.0"
        builds[arch] = int(item.findtext("s:version", namespaces=NS))
        requirement = item.findtext("s:hardwareRequirements", namespaces=NS)
        assert requirement == ("arm64" if arch == "arm64" else None)
        assert item.find("description") is not None, "Embed notes to avoid broken release-note links"
        subprocess.run([str(tools / "sign_update"), "--account", account, "--verify", str(dmg),
                        enclosure.attrib[f"{{{SPARKLE}}}edSignature"]], check=True)
        digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
        cask_arch = "arm" if arch == "arm64" else "intel"
        assert re.search(rf'{cask_arch}:\s+"{digest}"', cask), "Cask checksum/architecture mismatch"
        checksums.append(f"{digest}  {name}")
        subprocess.run(["codesign", "--verify", "--strict", str(dmg)], check=True)
        subprocess.run(["xcrun", "stapler", "validate", str(dmg)], check=True)
        validate_bundle(dmg, arch, builds[arch], plist)
    assert builds["arm64"] > builds["x86_64"] > 111, "ARM must outrank the Intel/Rosetta fallback"
    assert set((dist / "SHA256SUMS.txt").read_text().splitlines()) == set(checksums)
    legacy = ET.parse(dist / f"appcast-{version}/appcast.xml").findall("channel/item")
    assert len(legacy) == 1 and legacy[0].find("enclosure") is None
    assert int(legacy[0].findtext("s:version", namespaces=NS)) > 111
    assert legacy[0].findtext("link") == f"https://github.com/{repository}/releases/tag/{tag}"
    print("Verified signed feed, both update signatures, architecture routing, notarization, checksums, and legacy notice.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dist", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--account", default="menubox")
    parser.add_argument("--repository", default="elixirevo/menubox")
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    validate(args.dist, args.version, args.account, args.repository, args.tag)
