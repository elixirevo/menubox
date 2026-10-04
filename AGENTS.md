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
  열람/저장을 동의로 기록하지 않는다. GPL 앱 실행에 약관 동의를 강제하지 않는다.
- 최종 확인용 앱은 `dist/MenuBox.app`에 빌드한다. `artifacts/`는 진단 자료와
  격리된 UI 검증용 복사본에 사용하며 최종 앱 경로와 혼동하지 않게 구분한다.
