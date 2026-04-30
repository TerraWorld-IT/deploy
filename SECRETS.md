# TerraWorld Secrets 가이드

모든 환경 변수와 시크릿의 **소유 위치**·**생성 방법**·**전달 방식**을 한 곳에 정리. 이 문서는 코드와 함께 유지된다.

> ⚠ 절대 시크릿 값 자체를 이 문서에 적지 말 것. 형식과 출처만 기록.

---

## 1. 공통 인프라 시크릿 (`deploy/.env`)

`docker-compose up` 으로 띄우는 컨테이너들이 환경 변수로 받는다. 운영 서버에서 `.env` 파일로 관리하거나, GitHub Actions 의 `Settings → Secrets` 에 저장 후 deploy workflow 에서 주입.

| 이름 | 사용처 | 생성 방법 |
|---|---|---|
| `DB_HOST` / `DB_PORT` / `DB_NAME` | Postgres 연결 | 운영 PG 인스턴스 정보 |
| `DB_USER` / `DB_PASSWORD` | Postgres 인증 | DBA 발급 |
| `BETTER_AUTH_SECRET` | Nitro 세션 쿠키 서명 + auth.jwks 개인키 wrap | `openssl rand -hex 32` |
| `INTERNAL_API_TOKEN` | better-auth → Spring 내부 부트스트랩 헤더 (X-Internal-Token) | `openssl rand -hex 32`. **FE/BE 양쪽 동일값** |
| `AUTH_JWKS_URL` | Spring 이 fetch 할 JWKS 엔드포인트 | 고정 (`https://terraworld.app/api/auth/jwks`) |
| `AUTH_JWT_ISSUER` / `AUTH_JWT_AUDIENCE` | Spring claim 검증 강제값 | 고정 (`terraworld` / `terraworld-api`) |
| `CORS_ALLOWED_ORIGINS` | Spring CORS 허용 origin | `https://terraworld.app` (prod), localhost 포함 시 prod 부팅 fail |
| `REDIS_HOST` / `REDIS_PORT` | Redis 연결 | 컨테이너 기본 (`redis` / `6379`) |

---

## 2. Backend (Spring) 전용 시크릿

`deploy/.env` 의 값이 그대로 컨테이너 env 로 주입된다. 별도 GitHub Secret 은 CI 빌드용:

| 이름 | 사용처 | 위치 |
|---|---|---|
| `OPENAPI_SUBMODULE_TOKEN` | backend CI 가 `openapi-backend` 사설 submodule 을 checkout 할 때 PAT | `TerraWorld-IT/backend` repo Settings → Secrets |

PAT 권한: `repo` (read). 발급 위치: GitHub Account → Settings → Developer settings → Personal access tokens.

---

## 3. Frontend (Nuxt) 공개 환경 변수

`NUXT_PUBLIC_*` prefix 는 클라이언트 번들에 들어간다. **민감 정보는 절대 포함 금지** — public ID 만.

| 이름 | 사용처 | 비공개 / 공개 |
|---|---|---|
| `NUXT_PUBLIC_API_BASE_URL` | OpenAPI SDK base URL | 공개 |
| `NUXT_PUBLIC_AUTH_BASE_URL` | better-auth Nitro URL | 공개 |
| `NUXT_PUBLIC_GA_ID` | Google Analytics 4 측정 ID | 공개 |
| `NUXT_PUBLIC_ADSENSE_CLIENT` | AdSense `ca-pub-...` ID | 공개 |
| `NUXT_PUBLIC_ADSENSE_SLOT` | AdSense 슬롯 ID | 공개 |
| `NUXT_PUBLIC_ADMOB_REWARDED_AD_ID` | AdMob 보상형 광고 단위 ID | 공개 |

---

## 4. Frontend 서버 전용 시크릿 (Nitro)

| 이름 | 사용처 | 출처 |
|---|---|---|
| `DATABASE_URL` | better-auth Postgres 연결 (`auth` 스키마) | `deploy/.env` 에서 컴포즈 |
| `BETTER_AUTH_SECRET` | 위 1번 참조 | `deploy/.env` |
| `INTERNAL_API_TOKEN` | 위 1번 참조 | `deploy/.env` |
| `INTERNAL_API_BASE_URL` | Spring 내부 엔드포인트 | 고정 (`http://backend:8080`) |

---

## 5. Mobile (Capacitor / Android) 시크릿

`mobile/` repo 의 GitHub Actions Secrets 에 저장. 로컬 빌드 시에는 환경변수로 export.

| 이름 | 사용처 | 생성 |
|---|---|---|
| `ANDROID_KEYSTORE_BASE64` | release 서명 키 (base64 인코딩) | `keytool -genkey ...` 후 `base64 -w0 keystore.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 비밀번호 | keystore 생성 시 입력 |
| `ANDROID_KEY_ALIAS` | 키 alias | 보통 `terraworld` |
| `ANDROID_KEY_PASSWORD` | 키 비밀번호 | keystore 생성 시 입력 |

상세는 [`mobile/README.md`](../mobile/README.md) "Release 서명 keystore 설정" 참고.

---

## 6. Deploy 시크릿 (CI → 서버)

| 이름 | 사용처 |
|---|---|
| `DEPLOY_HOST` | 운영 서버 IP/도메인 |
| `DEPLOY_USER` | SSH 사용자 |
| `DEPLOY_SSH_KEY` | SSH private key (CI → 서버 접속) |
| `REGISTRY_URL` | 컨테이너 레지스트리 (예: `ghcr.io/terraworld-it`) |

---

## 7. 운영 절차

### 신규 시크릿 추가 시 체크리스트

1. 생성 방법 명시 (`openssl rand`, `keytool`, 외부 콘솔 등)
2. 본 문서에 행 추가
3. 영향받는 `.env.example` 파일에 변수 행 추가 (값은 placeholder)
4. 코드에서 사용 시 fallback / fail fast 정책 명시
5. CI / docker-compose 의 environment 매핑 검증
6. 양쪽 (FE+BE) 공유 시 "MUST match exactly" 주석 작성

### 시크릿 회전 (rotation)

#### `BETTER_AUTH_SECRET`

`auth.jwks` 의 RSA 개인키들이 이 secret 으로 wrap 되어 있다. 회전 시 기존 wrap 을 풀 수 없어 새 키 페어로 전환 필요.

**절차** (운영 시간 외, KST 02:00~05:00 권장):

1. 새 secret 생성: `openssl rand -hex 32`
2. FE / BE 의 `.env` 동시 갱신 (deploy/.env)
3. Nitro 재시작 — better-auth 가 자동으로 새 RSA key pair 를 `auth.jwks` 에 insert
4. **구 jwks row 5분 grace period 유지** — 회전 직전 발급된 JWT (5분 TTL) 가 만료되기 전까지는 구 키로도 검증되어야 함. 즉시 삭제하면 발급된 토큰이 무효화됨.
5. 5분 후 `DELETE FROM auth.jwks WHERE created_at < (NOW() - INTERVAL '5 minutes')` — 또는 better-auth 자동 cleanup 정책 활용
6. Spring backend 의 JWKS cache 강제 refresh — `JwtTokenProvider` 의 30s rate-limit 이 자연 만료 후 새 키 fetch. 즉시 적용은 backend 재시작.

**효과**: 회전 시점에 발급된 모든 JWT 와 세션 쿠키는 grace period 후 무효. 사용자는 다시 로그인.

#### `INTERNAL_API_TOKEN`

FE (Nitro) ↔ BE (Spring internal endpoint) 사이 X-Internal-Token 검증값. **양쪽 동일값 필수**.

**Zero-downtime 회전** (운영 안정 후 별도 PR 필요):

1. BE 코드에 dual-accept 모드 추가 — 환경변수 `INTERNAL_API_TOKEN` (신) + `INTERNAL_API_TOKEN_PREVIOUS` (구) 둘 다 검증 통과
2. BE 배포 → 양 토큰 모두 검증 가능 상태
3. FE 환경변수 갱신 (구 → 신)
4. FE 재배포 → 모든 호출이 신 토큰
5. BE 의 `INTERNAL_API_TOKEN_PREVIOUS` 제거 후 재배포

**dual-accept 모드 미구현 상태에서는 운영 시간 외 동시 재시작이 유일.**

#### `ANDROID_KEYSTORE_*`

**회전 불가**. 동일 appId 로 Play Store 업데이트 시 동일 keystore 서명 필수. keystore 파일 분실 또는 노출 시 :

- 분실 → appId 영구 불사용 (사용자에게 신규 앱 재설치 안내, 데이터 마이그레이션 별도)
- 노출 → 즉시 새 keystore 생성 + 신규 appId (`app.terraworld.mobile.v2`) 출시. 구 앱은 deprecated 표시.

**예방**: GitHub Secret 에만 보관 + 본인 1Password / 회사 secret manager 백업.

#### 그 외

- `DB_PASSWORD` — 운영 시간 외 회전. 5분 미만 downtime 허용 시 단순 갱신 + 재시작. zero-downtime 은 read replica 활용.
- `OPENAPI_SUBMODULE_TOKEN` (PAT) — 만료 전 갱신. GitHub Actions Secret 만 변경 (코드 변경 X).

### 절대 하지 말 것

- 시크릿 값 자체를 commit (`.env`, `.keystore`, `*.pem` 등)
- 프로덕션 시크릿을 dev 환경에서 사용
- public 채널 (Slack, GitHub Issue) 에 시크릿 평문 공유
- LLM 프롬프트에 시크릿 직접 입력
