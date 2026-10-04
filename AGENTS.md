# MenuBox 작업 규칙

## MacAppEssentials

- 연결/업데이트 전에 `../tools/library/docs/agent-integration.md`,
  `../tools/library/docs/settings-configuration.md`,
  `../tools/library/docs/integration.md`를 읽는다.
- 이용약관과 개인정보 처리방침은 설정 > 도움말 및 지원에서 열람한다.
  문서별 사이드바 탭·설정 카테고리·사용자 페이지를 추가하지 않는다.
- 확정된 HTTPS 문서가 있으면 `SupportSettingsModel(legalLinks:)`와
  `SupportLegalLinks`를 사용한다. 공개 URL이 없는 현재 약관은 공통 지원
  페이지의 `supportContent`에서 앱에 포함된 문서를 읽기 전용 시트로 연다.
  URL이나 개인정보 처리방침 내용을 임의로 만들지 않는다.
- 기존 약관 이동 목적지도 `SupportLegalLinks.settingsPageID`로 연결한다.
  열람/저장을 동의로 기록하지 않는다.
- 2026-10-05 사용자 지시에 따라 약관의 명시적 동의를 앱 사용 조건으로 적용한다.
  첫 실행은 기능 안내(설정 안내는 4단계) → 약관 동의 → 권한/선택 설정 순서다.
  `TermsAgreementModel`과 별도 버전별 저장소를 사용하고, 동의 전 기능·단축키·
  업데이트·Sentry 시작을 제한한다. 온보딩 완료를 동의로 이전하지 않는다.
  기존 사용자의 새 약관은 독립 동의 창으로 받고, 미동의 닫기는 종료한다.
  약관 동의가 선택적 충돌 보고나 OS 권한 승인을 대신하지 않는다.
- 최종 확인용 앱은 `dist/MenuBox.app`에 빌드한다. `artifacts/`는 진단 자료와
  격리된 UI 검증용 복사본에 사용하며 최종 앱 경로와 혼동하지 않게 구분한다.
