# TerraWorld 프로덕션 셋업 가이드 (외부 인프라 호스팅)

인프라 호스팅 담당(외부 개발자)이 자기 서버 + `web-qplay.kr` 서브도메인에 스택을
올리는 절차. 인프라 종속값은 전부 `deploy/.env` 로 외부화되어 있어, **도메인·크리덴셜만
채우면** 됨. 앱(모바일)은 원격 WebView 셸이라 이 웹 스택이 떠 있어야 동작한다.

> ⚠️ 본 설정은 대상 인프라에서 실측되지 않음(개발 측에 서버 없음). 첫 배포 시 각 단계
> 로그를 확인하며 진행할 것. 문제 시 이슈로 회신.

## 0. 구성 요약
```
   인터넷 ──▶ nginx(80/443, TLS) ──▶ /api/auth/* → frontend(Nitro, better-auth)
                                     /api/*      → backend(Spring)
                                     /           → frontend(Nuxt SSR)
   backend ─ postgres(public=Flyway) + auth(better-auth) ─ redis
```
단일 Postgres, 2 스키마(`public`/`auth`). 인증은 비대칭 RS256(frontend 발급 → backend JWKS 검증).

## 1. 사전 준비 (호스팅 담당)
- 리눅스/맥 서버 1대 (Docker + Docker Compose v2). 공인 IP.
- 포트 80/443 인바운드 개방.
- **DNS**: `web-qplay.kr` 존에 서브도메인 A 레코드 → 서버 공인 IP.
  - 예: `terraworld.web-qplay.kr  A  <서버IP>` (Cloudflare 사용 시 최초 발급 땐 **DNS-only/회색구름**으로 두고 certbot 발급 후 proxy 켜기 권장).
  - 서브도메인명은 자유. 정한 값을 `DEPLOY_DOMAIN` 으로 사용.

## 2. 이미지 확보 (2가지 중 택1)
스택은 `${REGISTRY_URL}/terraworld-backend:${TAG}` / `-frontend:${TAG}` 이미지를 pull 한다.
- **(A) GitHub Actions 로 빌드·푸시** (권장): 각 리포(`TerraWorld-IT/frontend`,`backend`)의
  `deploy.yml` 이 main push 시 이미지 빌드→레지스트리 push→SSH 배포까지 한다. 이때 §5 의 CI
  시크릿을 채우면 자동. `REGISTRY_URL` 을 호스팅 담당 레지스트리로 바꿔도 됨.
- **(B) 서버에서 직접 빌드**: 두 리포를 clone 후 `docker build` 하고 로컬 태그 사용
  (`REGISTRY_URL` 을 로컬 이름으로). 소규모면 이 방식도 무방.

## 3. 배포 (부트스트랩)
```sh
git clone https://github.com/TerraWorld-IT/deploy.git /opt/terraworld
cd /opt/terraworld
./scripts/bootstrap.sh          # 도메인/DB비번/레지스트리/이메일 대화식 입력
# 비대화식 예:
# DEPLOY_DOMAIN=terraworld.web-qplay.kr DB_PASSWORD='...' \
#   REGISTRY_URL=ghcr.io/terraworld-it ACME_EMAIL=you@web-qplay.kr ./scripts/bootstrap.sh --yes
```
부트스트랩이 하는 일: `.env` 생성(시크릿 openssl 생성 + 도메인 propagate) → pg/redis 기동
→ **auth 스키마 적용**(Flyway V5 이전, `db/auth/*.sql`) → backend/frontend 기동 → **certbot
최초 발급**(standalone) → nginx 기동 → 헬스체크.

수동으로 하려면: `cp env.production.example .env` 후 값 채우고, `docker compose up -d postgres redis`
→ auth SQL 적용 → `up -d backend frontend` → certbot 발급 → `up -d nginx`.

## 4. TLS 갱신 (cron, host)
```sh
0 3 * * * cd /opt/terraworld && docker compose run --rm --entrypoint certbot certbot \
  renew --webroot -w /var/www/certbot \
  --deploy-hook "docker compose exec nginx nginx -s reload"
```

## 5. CI(GitHub Actions) 시크릿 — 자동 배포용
`TerraWorld-IT/frontend`,`TerraWorld-IT/backend` 리포 → Settings → Secrets → Actions:
| 시크릿 | 값 |
|---|---|
| `REGISTRY_URL` / `REGISTRY_USERNAME` / `REGISTRY_PASSWORD` | 이미지 push 대상 레지스트리 |
| `DEPLOY_HOST` / `DEPLOY_USER` / `DEPLOY_SSH_KEY` | 배포 서버 SSH (배포 경로 `/opt/terraworld`) |
| `API_BASE_URL` | `https://<DEPLOY_DOMAIN>/api/v1` (frontend 빌드타임) |
| (frontend) `OPENAPI_FRONTEND_TOKEN` / (backend) `OPENAPI_SUBMODULE_TOKEN` | private SDK 서브모듈 체크아웃 PAT |

> `deploy.yml` 은 이미지 태그를 push 하지만 서버는 compose 의 `${TAG}`(기본 latest)를 pull 한다.
> 정확한 롤백 원하면 서버 `.env` 의 `TAG` 를 커밋 SHA 로 두고 배포마다 갱신.

## 6. 모바일 프로덕션 빌드 (도메인 확정 후)
앱은 `server.url` 을 **빌드타임에 baking**. 프로덕션 URL 은 이제 env 로 파라미터화됨:
- `mobile/capacitor.config.ts` production = `process.env.MOBILE_PROD_URL ?? 'https://terraworld.app'`.
- 프로덕션 빌드 시 `MOBILE_PROD_URL=https://<DEPLOY_DOMAIN>` 주입 (release.yml 에 반영 필요).
- **Universal/App Links**(선택, deep link): 도메인 확정 시 아래를 서브도메인으로 교체 후 재빌드
  - `mobile/ios/App/App/App.entitlements` 의 `applinks:terraworld.app`
  - `mobile/android/app/src/main/AndroidManifest.xml` 의 applinks host
  - (앱 기본 동작엔 불필요 — WebView 로딩은 applinks 무관)
- ⚠️ `mobile/.github/workflows/release.yml` 에는 이번 LAN 테스트에서 잡은 버그(admob 8,
  `-project`, 무서명→서명, Xcode 26, 기기등록)가 아직 미반영. 프로덕션 빌드 전 동일 수정 필요.
  (LAN 테스트용 `ios-lan-test.yml` 은 수정 완료 — 참고 대상)

## 7. 검증 체크리스트
- [ ] `https://<DEPLOY_DOMAIN>/` → 200 (Nuxt SSR)
- [ ] `https://<DEPLOY_DOMAIN>/api/auth/jwks` → 200 JSON (RS256 keys) — **auth 라우팅 핵심**
- [ ] `https://<DEPLOY_DOMAIN>/api/v1/items` → 200 (backend permitAll)
- [ ] signup → 로그인 → 보호 API 200 (backend JWKS 검증 동작)
- [ ] `docker compose ps` 전부 healthy
- [ ] `bash scripts/check-applinks.sh https://<DEPLOY_DOMAIN>` (deep link 쓸 경우)

## 8. 주의 (설계 결정)
- postgres/redis/backend/frontend 는 **호스트 포트 미노출**(nginx 경유만). 디버깅 필요 시 임시 노출.
- prod 프로파일은 `AUTH_JWKS_URL`/`INTERNAL_API_TOKEN`/`CORS_ALLOWED_ORIGINS` 없거나 localhost 포함 시 **부팅 실패**(의도된 fail-fast).
- `AUTH_JWKS_URL` 은 공개 URL 이 아니라 **내부 `http://frontend:3000/...`** (nginx hairpin 회피).
