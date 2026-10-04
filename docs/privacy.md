# MenuBox privacy policy integration

The app owns policy 1.0, effective 2026-10-05, in
`Sources/MenuBox/Resources/{ko,en}.lproj/PrivacyPolicy.txt`. It follows the shared
package's `docs/legal/privacy-template-guide.md` and both language templates.
The operator previously confirmed elixirevo, Republic of Korea and
elixirevo@gmail.com. On 2026-10-05 the operator confirmed support email deletion
within one year after resolution. No public policy URL was supplied.

Settings → Help & Support contains an offline read/save sheet alongside Terms.
It uses the app language, selectable full text and a native save panel. No new
sidebar category, remote request, acceptance receipt or usage gate is added.
Terms 1.1 and reporting preferences are unchanged. Both translations must be
present and byte-identical to the source during bundle creation.

## Evidence checked on 2026-10-05

- Local behavior: SettingsStore, MenuBoxTerms, NativeMenuBarRecovery,
  MenuBarAccessDiagnostics and the active controller/menu paths. Recovery records
  are deleted on successful restoration; preferences and optional diagnostic
  files have distinct lifetimes. ScreenCapture helpers remain in source but the
  current controller does not invoke them; do not claim active screen recording.
- Sentry: the actual MacAppDiagnosticsSentry options and beforeSend filter; the
  SDK only starts with its separate launch-time reporting preference after terms
  acceptance. Cache count 20 is not a time limit or an immediate deletion policy.
- Project API: default data scrubber enabled; IP scrubbing is not enabled. Never
  claim complete anonymity. No server settings or user preferences were changed.
- DSN: US-region ingestion. Sentry subscription UI showed Business-feature trial,
  with 13 days left, rather than a confirmed paid subscription. Retention language
  states published paid/Developer criteria and the observed trial, without
  promising an account-specific deletion deadline or treating backups as events.
- Sparkle source: User-Agent uses app name/version and Sparkle version; system
  profile is not enabled by the app by default. Feed/download host is GitHub.
- Support uses the confirmed Gmail address and public GitHub issues. Copy/save
  of support diagnostics does not submit them. Provider access-log and backup
  deletion intervals are not controlled by the app.

## Official references

- [Korean PIPA article 30](https://www.law.go.kr/lsLinkCommonInfo.do?lsJoLnkSeq=1029335711)
- [Korean PIPA article 28-8](https://www.law.go.kr/LSW/lsLinkCommonInfo.do?chrClsCd=010202&lsJoLnkSeq=1029334957)
- [Sentry retention distinctions](https://www.sentry.help/en/articles/13964940-how-long-are-my-organization-s-audit-logs-stored)
- [Sentry regional storage](https://www.sentry.help/en/articles/13965013-where-are-your-data-servers-located)
- [Sentry privacy policy](https://sentry.io/privacy/)
- [GitHub privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement)
- [Google privacy policy](https://policies.google.com/privacy)
- [Korean dispute mediation](https://www.kopico.go.kr/)
- [Korean infringement report center](https://privacy.kisa.or.kr/)

## Publication review

This is a disclosure of verified implementation and the operator's stated policy,
not a certification of legal compliance. A public release should review the
operator's legal-name/address and any required phone disclosures, processor
agreements, applicable processing/transfer bases and any separate transfer
consent, provider-specific retention (including trial transitions and backups),
actual overseas processing countries, and applicable US-state requirements.
Unverified provider contracts, deletion intervals, safeguards and legal grounds
were not invented. Reading this document does not create transfer consent.
Adding this policy did not publish a release or change provider configuration.

## Verification

Local ARM64 build 1.5.1 (155) is in `dist/MenuBox.app`, Developer ID signed.
206 tests completed: 204 passed, two existing opt-in tests skipped. Resource
checks compared both bundled policies and terms to their source files. Native
UI checks covered Korean/dark and English/light sheets through the last section,
Escape returning to Support, and the Korean save panel/export; the exported file
was byte-identical to the bundled policy. Screenshots and the test export remain
in `artifacts/privacy-qa/`. The published 1.5.1 assets are unchanged.
