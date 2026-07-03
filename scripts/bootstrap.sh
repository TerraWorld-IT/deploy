#!/usr/bin/env sh
# TerraWorld 프로덕션 부트스트랩 (macOS/Linux, Docker 필요).
# 하는 일: 사전점검 → .env 생성(도메인 입력 + 시크릿 생성) → auth 스키마 적용
#          → certbot 최초 발급 → 스택 기동 → 헬스체크.
#
# 사용:  cd deploy && ./scripts/bootstrap.sh
#   비대화식: DEPLOY_DOMAIN=... DB_PASSWORD=... REGISTRY_URL=... ACME_EMAIL=... ./scripts/bootstrap.sh --yes
#
# ⚠️ 실행 전: 도메인 DNS A 레코드가 이 호스트 공인 IP 로 이미 향해 있어야 함(certbot 발급 조건).
# ⚠️ 본 스크립트는 대상 인프라에서 실측되지 않음 — 첫 실행 시 각 단계 로그 확인 권장.
set -eu
cd "$(dirname "$0")/.."   # deploy/

log() { printf '\033[1;32m[bootstrap]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[bootstrap:ERROR]\033[0m %s\n' "$*" >&2; }
ask() { # ask VAR "prompt" "default"
  eval "cur=\${$1:-}"; if [ -n "${cur:-}" ]; then return 0; fi
  printf '%s [%s]: ' "$2" "${3:-}"; read ans || true
  eval "$1=\"\${ans:-$3}\""
}

# ── 0) 사전 점검 ─────────────────────────────────────────────────────────────
for c in docker openssl; do command -v "$c" >/dev/null 2>&1 || { err "$c 미설치"; exit 1; }; done
docker compose version >/dev/null 2>&1 || { err "'docker compose' 불가 (Docker Desktop/Compose v2 필요)"; exit 1; }
log "사전 점검 통과 (docker, compose, openssl)"

# ── 1) .env 생성 ─────────────────────────────────────────────────────────────
if [ -f .env ]; then
  log ".env 존재 — 재사용 (새로 만들려면 삭제 후 재실행)"
else
  log ".env 생성 — 필요한 값을 입력하세요 (Enter=기본값)"
  ask DEPLOY_DOMAIN  "배포 도메인(web-qplay.kr 서브도메인)" "terraworld.web-qplay.kr"
  ask DB_NAME        "DB 이름" "terraworld"
  ask DB_USER        "DB 유저" "terraworld"
  ask DB_PASSWORD    "DB 비밀번호(강한 값)" "$(openssl rand -hex 16)"
  ask REGISTRY_URL   "컨테이너 레지스트리" "ghcr.io/terraworld-it"
  ask TAG            "이미지 태그" "latest"
  ask IOS_TEAM_ID    "Apple Team ID(AASA용, 없으면 비움)" ""
  ask ANDROID_SHA256_FINGERPRINT "Android keystore SHA-256(없으면 비움)" ""
  BAS="$(openssl rand -hex 32)"; IAT="$(openssl rand -hex 32)"
  ENC_PW="$(printf '%s' "$DB_PASSWORD" | sed 's/@/%40/g; s#/#%2F#g; s/:/%3A/g')"  # URL 인코딩(민감문자)
  umask 077
  cat > .env <<EOF
DEPLOY_DOMAIN=${DEPLOY_DOMAIN}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/${DB_NAME}?currentSchema=public
DATABASE_URL=postgresql://${DB_USER}:${ENC_PW}@postgres:5432/${DB_NAME}?options=-c%20search_path%3Dauth%2Cpublic
BETTER_AUTH_SECRET=${BAS}
BETTER_AUTH_URL=https://${DEPLOY_DOMAIN}
AUTH_JWKS_URL=http://frontend:3000/api/auth/jwks
AUTH_JWT_ISSUER=terraworld
AUTH_JWT_AUDIENCE=terraworld-api
INTERNAL_API_TOKEN=${IAT}
INTERNAL_API_BASE_URL=http://backend:8080
CORS_ALLOWED_ORIGINS=https://${DEPLOY_DOMAIN}
REDIS_HOST=redis
REDIS_PORT=6379
SPRING_PROFILES_ACTIVE=prod
NUXT_PUBLIC_API_BASE_URL=https://${DEPLOY_DOMAIN}/api/v1
NUXT_PUBLIC_AUTH_BASE_URL=https://${DEPLOY_DOMAIN}
REGISTRY_URL=${REGISTRY_URL}
TAG=${TAG}
IOS_TEAM_ID=${IOS_TEAM_ID}
ANDROID_SHA256_FINGERPRINT=${ANDROID_SHA256_FINGERPRINT}
EOF
  log ".env 생성 완료 (secret 2개 openssl 생성, 도메인 propagate). 권한 600."
fi
# shellcheck disable=SC1091
. ./.env

# ── 2) DB/Redis 기동 + auth 스키마 적용(backend Flyway V5 이전) ──────────────
log "postgres + redis 기동..."
docker compose up -d postgres redis
log "postgres healthy 대기..."
i=0; until docker compose exec -T postgres pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -gt 30 ] && { err "postgres 준비 실패"; exit 1; }; sleep 2; done
log "auth 스키마 적용 (db/auth/*.sql)..."
for f in db/auth/001_better_auth_init.sql db/auth/002_better_auth_user_birthDate.sql db/auth/003_user_consent_fields.sql; do
  log "  $f"
  docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" < "$f"
done

# ── 3) 앱 기동 (backend Flyway V1..Vn, frontend Nitro) ───────────────────────
log "backend + frontend 기동 (이미지 pull)..."
docker compose pull backend frontend || true
docker compose up -d backend frontend

# ── 4) TLS 최초 발급 (cert 없으면 standalone) ────────────────────────────────
if docker compose run --rm --entrypoint sh certbot -c "[ -f /etc/letsencrypt/live/${DEPLOY_DOMAIN}/fullchain.pem ]" 2>/dev/null; then
  log "인증서 이미 존재 — 발급 건너뜀"
else
  ask ACME_EMAIL "Let's Encrypt 알림 이메일" ""
  log "certbot standalone 최초 발급 (포트 80 사용, nginx 아직 미기동)..."
  docker compose run --rm -p 80:80 --entrypoint certbot certbot \
    certonly --standalone -d "$DEPLOY_DOMAIN" \
    ${ACME_EMAIL:+--email "$ACME_EMAIL"} ${ACME_EMAIL:+--no-eff-email} \
    --agree-tos -n || { err "certbot 발급 실패 — DNS A레코드/포트80 개방 확인"; exit 1; }
fi

# ── 5) nginx 기동 + 헬스체크 ─────────────────────────────────────────────────
log "nginx 기동..."
docker compose up -d nginx
sleep 3
log "헬스체크..."
docker compose ps
if command -v curl >/dev/null 2>&1; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${DEPLOY_DOMAIN}/" || echo 000)
  log "https://${DEPLOY_DOMAIN}/ -> HTTP ${code} (200/3xx 정상)"
  acode=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${DEPLOY_DOMAIN}/api/auth/jwks" || echo 000)
  log "https://${DEPLOY_DOMAIN}/api/auth/jwks -> HTTP ${acode} (200 이면 auth 라우팅 정상)"
fi
log "완료. 갱신 cron 예시는 docs/production-setup.md 참고."
