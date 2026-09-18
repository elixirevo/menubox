# Releasing MenuBox

Public releases require a **Developer ID Application** signing identity, the `menubox` notarytool keychain profile, and the Sparkle private key stored under account `menubox`. Private keys and credentials must never be committed. `sparkle-public-key.txt` and `Resources/Info.plist` contain only the public key.

## Prepare and publish

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, and write `docs/releases/<version>.md`. The plist build number is the Intel build; Apple Silicon uses the next number, so Sparkle prefers it over the Intel/Rosetta fallback. Both must exceed all previously published builds.
2. Run `swift test` and prepare artifacts:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
   SIGN_IDENTITY='Developer ID Application: Songwoo Yi (74DXCK2J5Q)' \
   NOTARY_PROFILE=menubox bash scripts/release.sh
   ```

   The script signs nested Sparkle helpers and the app, notarizes and staples the app, packages and signs each DMG, then notarizes and staples the DMG. It generates the signed feed, verifies signatures and checksums, and updates both cask copies. To reuse already notarized DMGs, set `SKIP_BUILD=1`. Submission IDs and Apple logs remain in `dist/notarization`; interrupted submissions can be queried with `xcrun notarytool info <id> --keychain-profile menubox`.
3. Review and commit the app repository changes, including final cask checksums. The sibling `homebrew-tap` checkout must contain `Casks/menubox.rb` and the rename mapping. Then publish:

   ```sh
   RELEASE_PHASE=publish bash scripts/release.sh
   ```

   Publication validates the artifacts again, pushes the commit and tag, creates a draft with all assets, publishes it as latest, and commits/pushes the tap. It refuses to overwrite an existing release. Keep `dist` until remote downloads, both appcast URLs and the Homebrew migration have been verified.

## Update feeds and the 1.2 transition

- `menubox-appcast.xml`: the signed feed for MenuBox 1.2+, with signed architecture-specific DMGs and embedded release notes. The app requires signed feeds and verifies archives before extraction.
- `appcast.xml`: the informational feed for StatusBox 1.1 and pre-release MenuBox builds with the old key. It deliberately contains no enclosure and links to the manual/Homebrew upgrade instructions. Continue uploading this asset on future releases because old apps use `/releases/latest/download/appcast.xml`. The former GitHub repository URL redirects to `elixirevo/menubox`.
- StatusBox 1.0 has no updater. The lost old key and its ad-hoc code signature prevent a trusted automatic installation from StatusBox 1.1. Do not claim automatic installation is supported for these builds.

The app name, executable, bundle identifier, repository and cask are MenuBox/menubox. Old StatusBox identifiers remain only for settings migration and the legacy feed. Permissions and login registration need to be granted to the renamed app.

## Back up the new Sparkle key

The private key resides in the login Keychain under account `menubox`. Export it to a secure location outside the repository, then store it in an encrypted backup/password manager:

```sh
umask 077
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account menubox -x /path/to/secure-backup/menubox-sparkle.key
```

That file contains the private key in plaintext; the destination must be protected. On another Mac, import with `generate_keys --account menubox -f /path/to/secure-backup/menubox-sparkle.key`. Use `generate_keys --account menubox -p` to verify the public key matches `sparkle-public-key.txt`. Keep a password-protected `.p12` backup of the Developer ID identity and its private key as well.
