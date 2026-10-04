#!/usr/bin/env python3
"""Match MenuBox dSYMs to packaged executables and upload them before publication."""
import argparse
from dataclasses import dataclass
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from uuid import UUID

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "Sources/MenuBox/Resources/SentryConfiguration.json"


class SymbolError(Exception):
    pass


@dataclass(frozen=True)
class SymbolFile:
    path: Path
    uuid: str
    arch: str


def debug_ids(path):
    if not path.exists():
        raise SymbolError(f"Missing executable or dSYM: {path}")
    result = subprocess.run(["xcrun", "dwarfdump", "--uuid", str(path)],
                            capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise SymbolError(f"Cannot read debug UUIDs: {path}")
    matches = re.findall(r"^UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)", result.stdout, re.M)
    ids = {(str(UUID(value)), arch) for value, arch in matches}
    if not ids:
        raise SymbolError(f"No debug UUIDs: {path}")
    return ids


def matching_symbols(app, symbols, arch, version, build):
    """Call while the distribution DMG is mounted, not against dist/MenuBox.app."""
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    config = json.loads(CONFIG.read_text())
    if (info["CFBundleIdentifier"] != config["appIdentifier"]
            or info["CFBundleExecutable"] != "MenuBox"
            or info["CFBundleShortVersionString"] != version
            or str(info["CFBundleVersion"]) != str(build)):
        raise SymbolError("App identity/version/build does not match the release.")
    bundled = app / "Contents/Resources/MenuBox_MenuBox.bundle/Contents/Resources/SentryConfiguration.json"
    if json.loads(bundled.read_text()) != config:
        raise SymbolError("Packaged Sentry configuration differs from source.")
    path = symbols / f"MenuBox-{version}-{build}-{arch}.app.dSYM"
    executable_ids = debug_ids(app / "Contents/MacOS/MenuBox")
    if (len(executable_ids) != 1 or next(iter(executable_ids))[1] != arch
            or debug_ids(path) != executable_ids):
        raise SymbolError(f"App/dSYM UUID or architecture mismatch: {path}")
    return SymbolFile(path.resolve(), next(iter(executable_ids))[0], arch)


def setup_module():
    path = ROOT.parent / "tools/library/scripts/sentry-setup.py"
    if not path.is_file():
        raise SymbolError("Missing MacAppEssentials scripts/sentry-setup.py checkout.")
    spec = importlib.util.spec_from_file_location("menubox_sentry_setup", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def credentials(config):
    """Reuse the developer Keychain profile; CI only needs SENTRY_AUTH_TOKEN."""
    setup = setup_module()
    try:
        organization = setup.slug(config["organization"])
        project = setup.slug(config["project"])
        if "SENTRY_AUTH_TOKEN" in os.environ:
            base = setup.api_base(os.environ.get("SENTRY_API_BASE", "https://sentry.io/api/0/"))
            token = setup.token_from_keychain("", "")
        else:
            profile = setup.validate_profile(setup.read_json(setup.PROFILE))
            if profile["organization"] != organization:
                raise SymbolError("Developer profile organization differs from MenuBox configuration.")
            base = profile["apiBase"]
            token = setup.token_from_keychain(profile["keychainService"], profile["keychainAccount"])
        return setup.Client(base, token), token, organization, project
    except setup.SetupError as error:
        raise SymbolError(str(error)) from None


def upload_symbols(symbols):
    if not symbols:
        raise SymbolError("No validated dSYMs to upload.")
    # Recheck after unmounting, so replaced archives cannot silently pass the gate.
    for symbol in symbols:
        if debug_ids(symbol.path) != {(symbol.uuid, symbol.arch)}:
            raise SymbolError(f"dSYM changed after app validation: {symbol.path}")
    cli = shutil.which("sentry-cli")
    if not cli:
        raise SymbolError("Install sentry-cli first: brew install getsentry/tools/sentry-cli")
    client, token, organization, project = credentials(json.loads(CONFIG.read_text()))
    env = {key: value for key, value in os.environ.items() if not key.startswith("SENTRY_")}
    env.update(SENTRY_AUTH_TOKEN=token, SENTRY_LOAD_DOTENV="0", SENTRY_DISABLE_UPDATE_CHECK="1")
    command = [cli, "--url", client.base.removesuffix("api/0/"), "--log-level", "warn",
               "debug-files", "upload", "--org", organization, "--project", project,
               "--type", "dsym", "--wait-for", "300"]
    # CLI 3.8.0 --require-all falsely fails for IDs already on the server.
    # Local UUID matching plus the per-ID server checks below enforce completeness.
    for symbol in symbols:
        command.extend(["--id", symbol.uuid])
    command.extend(str(symbol.path) for symbol in symbols)
    print(f"Uploading {len(symbols)} matching dSYM(s) to {organization}/{project}…", flush=True)
    # Avoid repository-local CLI config/dotenv and never forward raw credential-bearing logs.
    with tempfile.TemporaryDirectory(prefix="menubox-symbols-") as working:
        result = subprocess.run(command, env=env, cwd=working, capture_output=True,
                                text=True, timeout=600)
    if result.returncode:
        raise SymbolError(f"Sentry symbol upload/processing failed (exit {result.returncode}). "
                          "Check connectivity and token project:write permission, then retry; publication is blocked.")
    for symbol in symbols:
        try:
            rows = client.get(f"projects/{organization}/{project}/files/dsyms/?debug_id={symbol.uuid}")
        except Exception:
            raise SymbolError("Cannot verify uploaded debug files with Sentry. Publication is blocked.") from None
        if not isinstance(rows, list) or not any(
                row.get("uuid", "").lower() == symbol.uuid
                and row.get("cpuName") == symbol.arch
                and "debug" in (row.get("data", {}).get("features") or [])
                for row in rows):
            raise SymbolError(f"Sentry has not confirmed debug information for {symbol.arch} UUID {symbol.uuid}.")
        print(f"Verified Sentry debug information: {symbol.arch} {symbol.uuid}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Standalone recovery/verification of a local app")
    parser.add_argument("--symbols", type=Path, required=True)
    parser.add_argument("--arch", choices=("arm64", "x86_64"), required=True)
    args = parser.parse_args()
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    symbol = matching_symbols(args.app, args.symbols, args.arch,
                              info["CFBundleShortVersionString"], info["CFBundleVersion"])
    upload_symbols([symbol])


if __name__ == "__main__":
    try:
        main()
    except (SymbolError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        # Subprocess exceptions can contain captured output; do not expose it.
        message = str(error) if isinstance(error, SymbolError) else type(error).__name__
        sys.exit(f"Sentry symbols failed: {message}")
