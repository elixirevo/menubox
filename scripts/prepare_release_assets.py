#!/usr/bin/env python3
"""Create the legacy feed and a source archive for the exact release checkouts."""
import argparse
import io
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent.parent


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args])


def package_sources(output, version):
    library = ROOT.parent / 'tools/library'
    for root in (ROOT, library):
        if git(root, 'status', '--porcelain').strip():
            raise RuntimeError(f'Commit source changes before packaging: {root}')
    if not (library / 'LICENSE').is_file():
        raise RuntimeError('MacAppEssentials LICENSE is required before distribution.')
    app_commit = git(ROOT, 'rev-parse', 'HEAD').decode().strip()
    library_commit = git(library, 'rev-parse', 'HEAD').decode().strip()
    prefix = f'MenuBox-{version}-source/'
    dependencies = json.loads((ROOT / 'Package.resolved').read_text())['pins']
    instructions = f'''# MenuBox {version} source

MenuBox commit: {app_commit}
MacAppEssentials commit: {library_commit}

The directory layout matches Package.swift's local package paths. Open a terminal
in menubox, install Xcode (including Command Line Tools), then run:

    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    swift package resolve
    swift test
    bash scripts/build_app.sh arm64

Use x86_64 instead of arm64 for an Intel build. The default signing identity is
ad-hoc; use your own signing identity for public distribution. No developer tokens,
Apple signing keys or Sparkle private keys are needed to build a modified copy.
See menubox/README.md, LICENSE, LICENSING.md, TRADEMARKS.md and THIRD_PARTY_NOTICES.txt.
MacAppEssentials has its own LICENSE in tools/library.

External dependency source (resolved by SwiftPM, exact pinned revisions):
'''
    for pin in dependencies:
        state = pin['state']
        url = pin['location'].removesuffix('.git')
        instructions += f"\n- {pin['identity']} {state.get('version', '')}: {url}/tree/{state['revision']}\n"
    target = output / f'MenuBox-{version}-source.tar.gz'
    temporary = target.with_suffix('.tmp')
    try:
        with tarfile.open(temporary, 'w:gz') as archive:
            for root, folder in ((ROOT, 'menubox/'), (library, 'tools/library/')):
                source = git(root, 'archive', '--format=tar', '--prefix=' + prefix + folder, 'HEAD')
                with tarfile.open(fileobj=io.BytesIO(source)) as original:
                    for member in original:
                        archive.addfile(member, original.extractfile(member) if member.isfile() else None)
            content = instructions.encode()
            member = tarfile.TarInfo(prefix + 'BUILDING.md')
            member.size, member.mode = len(content), 0o644
            archive.addfile(member, io.BytesIO(content))
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    print(f'Packaged source: {target}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    package_sources(args.output, args.version)
    subprocess.run(['python3', str(ROOT / 'scripts/generate_legacy_appcast.py'),
                    '--version', args.version, '--build', args.build, '--repository', args.repository,
                    '--tag', args.tag, '--output', str(args.output / 'appcast.xml')], check=True)


if __name__ == '__main__':
    main()
