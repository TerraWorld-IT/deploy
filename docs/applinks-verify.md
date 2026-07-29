# Universal Links / App Links 검증 Runbook

**Status**: Active
**Date**: 2026-05-16 (UltraPlan M21)
**Owner**: deploy + mobile
**Source**: UltraPlan v2 § 3 M21 + Codex round 1 verification gate

본 runbook 은 production deploy 후 iOS Universal Links (AASA) + Android App Links (assetlinks.json) 동작 검증 SOP. M21 backend infrastructure (`deploy/nginx/templates/default.conf.template` envsubst 패턴) 는 이미 구현됨 — 본 runbook 은 **실 검증** 영역.

---

> **도메인 표기 규약**: 아래 예시의 `terraworld.web-qplay.kr` 는 현재 배포 도메인이자
> `deploy/.env` 의 `DEPLOY_DOMAIN` 값이다. 도메인이 바뀌면 이 문서를 고치는 대신
> `DEPLOY_DOMAIN` 을 바꾸면 된다 — nginx 템플릿(envsubst)과 `scripts/check-applinks.sh`
> 가 모두 그 값을 따른다. 이 문서는 예전 도메인 `terraworld.app` 을 쓰고 있었고,
> mobile repo 의 entitlements / AndroidManifest 는 이미 `terraworld.web-qplay.kr` 이라
> 문서만 뒤처져 있었다.

## 1. Prerequisites

배포 환경에서 다음이 충족돼야 함:

- `https://terraworld.web-qplay.kr` DNS A/AAAA record 정상 (cloudflare proxy 통과)
- nginx-alpine container 가 `IOS_TEAM_ID` + `ANDROID_SHA256_FINGERPRINT` env 로 기동
- TLS 인증서 (Let's Encrypt) 유효
- iOS / Android 실 device (또는 emulator)

---

## 2. Layer 1 — Static endpoint 검증 (`scripts/check-applinks.sh`)

본 repo 의 기존 스크립트 사용:

```bash
cd deploy
# .env 의 DEPLOY_DOMAIN 을 그대로 쓰는 방법 (권장 — 도메인 오타 방지)
. ./.env && bash scripts/check-applinks.sh

# 도메인을 직접 주는 방법
bash scripts/check-applinks.sh https://terraworld.web-qplay.kr
# 또는 staging:
bash scripts/check-applinks.sh https://staging.terraworld.web-qplay.kr
```

인자를 생략하면 `DEPLOY_DOMAIN` 환경변수를, 그것도 없으면
`terraworld.web-qplay.kr` 를 기본값으로 쓴다.

검사 항목 (스크립트 본문 참조):

1. HTTP 200 응답
2. `Content-Type: application/json`
3. JSON 유효성 (jq parse)
4. **placeholder 잔존 검사** — `TEAMID` / `SHA256_FINGERPRINT_HERE` 가 남아있으면 fail
5. iOS appIDs suffix = `.app.terraworld.mobile`
6. Android package_name = `app.terraworld.mobile`

종료 코드 = 실패 개수. 0 이면 모든 항목 PASS.

---

## 3. Layer 2 — iOS Universal Links device 검증

### 3.1 device 사전 조건

- iOS 15+ device
- TerraWorld app 설치 (debug 또는 release build)
- `mobile/ios/App/App/App.entitlements` 의 `associated-domains` 가 `applinks:terraworld.web-qplay.kr` 포함

### 3.2 검증 단계

1. **device 의 system log capture** (macOS 필요):
   ```bash
   sudo log stream --predicate 'subsystem == "com.apple.swift.activatedActions"' --info
   ```

2. **테스트 URL 발송**:
   - Notes 앱에 `https://terraworld.web-qplay.kr/share/<sample-code>` 입력
   - 링크 탭 → TerraWorld app 진입 기대 (브라우저 아님)

3. **system log 확인**:
   - `Should activate domain ... allowed: 1` → AASA verify 통과
   - `allowed: 0` 또는 AASA fetch 실패 시 다음 확인:
     - `https://terraworld.web-qplay.kr/.well-known/apple-app-site-association` 가 200 + application/json (Layer 1 확인)
     - `appIDs` 의 `<TEAMID>.<bundleID>` 가 실 Apple Developer Team ID + 빌드 bundle ID 와 일치
     - app 가 처음 설치된 후 Apple CDN AASA fetch 대기 (~24시간)

4. **Apple AASA validator** (브라우저):
   - <https://branch.io/resources/aasa-validator/>
   - terraworld.web-qplay.kr 입력 → "valid AASA" 확인

### 3.3 알려진 실패 패턴

- `swcutil show` 의 cache 가 stale 시 → device 재부팅 또는 `swcutil reset`
- TestFlight 빌드는 production AASA 사용 — debug 빌드는 별도 entitlement (`com.apple.developer.associated-domains` 의 `?mode=developer` suffix) 필요

---

## 4. Layer 3 — Android App Links device 검증

### 4.1 device 사전 조건

- Android 6+ (API 23+)
- TerraWorld app 설치 (debug 또는 release build)
- `mobile/android/app/src/main/AndroidManifest.xml` 의 intent-filter 에 `autoVerify="true"` 설정

### 4.2 검증 단계

1. **assetlinks.json 의 SHA256 fingerprint 가 실 keystore 와 일치 확인**:
   ```bash
   keytool -list -v -keystore terraworld-release.jks -alias terraworld | grep SHA256
   # 출력: SHA256: 14:6D:E9:83:...
   ```
   `https://terraworld.web-qplay.kr/.well-known/assetlinks.json` 의 `sha256_cert_fingerprints` 와 byte-for-byte 일치해야 함.

2. **adb verify-app-links**:
   ```bash
   # 본 명령으로 app links 재검증 (cache invalidate + 새 verify)
   adb shell pm verify-app-links --re-verify app.terraworld.mobile

   # 검증 결과 조회
   adb shell pm get-app-links app.terraworld.mobile
   ```

   기대 출력:
   ```
   Domain verification state:
     terraworld.web-qplay.kr: verified
   ```

3. **chrome 에서 link 테스트**:
   - chrome 에서 `https://terraworld.web-qplay.kr/share/<sample-code>` 입력
   - 시스템 prompt 없이 (또는 "TerraWorld 로 열기" 선택) → app 진입 기대

4. **Digital Asset Links validator** (브라우저):
   - <https://developers.google.com/digital-asset-links/tools/generator>
   - source = `https://terraworld.web-qplay.kr`, target = `app.terraworld.mobile`
   - "links are valid" 확인

### 4.3 알려진 실패 패턴

- `pm get-app-links` 가 `none` 또는 `failed` 출력 → assetlinks.json content 오류 (placeholder 잔존, 잘못된 SHA256, 잘못된 package_name)
- Play Store 배포 후 fingerprint 가 release keystore vs Play App Signing key 와 달라질 수 있음 (Play Console 의 "App signing certificate" 페이지에서 실 fingerprint 확인 → assetlinks.json 갱신)
- chrome 캐시 — `adb shell pm clear com.android.chrome` 후 재시도

---

## 5. Layer 4 — CI 자동화 (선택)

`deploy/.github/workflows/applinks-check.yml` (신규 생성 권장 — 본 PR 비포함):

```yaml
name: AppLinks Verify (daily cron)
on:
  schedule:
    - cron: '0 4 * * *'  # 매일 UTC 04:00
  workflow_dispatch:

jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          sudo apt-get install -y jq curl
          bash scripts/check-applinks.sh https://terraworld.web-qplay.kr
```

- exit code 0 = PASS / 1+ = FAIL → workflow fail → Slack/Discord webhook 알림 (현재 deploy/ 의 Discord webhook config 재사용 가능)

---

## 6. 운영 체크리스트 (배포 직후)

배포 직후 다음 순서로 검증:

- [ ] `bash deploy/scripts/check-applinks.sh https://terraworld.web-qplay.kr` exit 0
- [ ] Branch.io AASA validator PASS
- [ ] Digital Asset Links validator PASS
- [ ] iOS device: Notes 링크 탭 → app 진입 (vs Safari)
- [ ] Android device: chrome 링크 탭 → app 진입 (vs chrome 내 페이지)
- [ ] `adb shell pm get-app-links app.terraworld.mobile` = `verified`
- [ ] system log: AASA cache hit + verify OK (iOS)
- [ ] Play Console SHA256 vs assetlinks.json byte-equal (Android, 배포 후)

---

## 7. References

- `deploy/nginx/templates/default.conf.template` (line 27-50) — AASA / assetlinks endpoints
- `deploy/scripts/check-applinks.sh` (기존 검증 스크립트)
- `mobile/ios/App/App/App.entitlements` (associated-domains)
- `mobile/android/app/src/main/AndroidManifest.xml` (autoVerify=true)
- UltraPlan 2026-05-16 v2 § 3 M21
- Apple AASA spec: <https://developer.apple.com/documentation/xcode/supporting-associated-domains>
- Android App Links spec: <https://developer.android.com/training/app-links/verify-android-applinks>
