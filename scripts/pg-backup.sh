#!/usr/bin/env bash
#
# P3-4 (O-DR-001): PostgreSQL 16 일일 백업 → (선택) GPG 암호화 → S3/R2 업로드 → 로컬 보존 정리.
# DR runbook §2.1 의 인라인 스크립트를 실 배선. cron 에서 호출 (deploy/scripts/crontab.terraworld-backup).
#
# 필수 env:  PGDATABASE 또는 -d 인자 (기본 terraworld), DATABASE_URL 또는 표준 PG* env 로 접속.
# 선택 env:  BACKUP_DIR(기본 /var/backups/postgres), S3_BUCKET, S3_PREFIX(기본 postgres/daily),
#            GPG_RECIPIENT(설정 시에만 암호화), RETENTION_DAYS(기본 7), DISCORD_WEBHOOK_URL.
#
# 안전: set -euo pipefail + 미설정 시 graceful skip(업로드/암호화/알림). 실패 시 비0 종료 → cron 메일/알림.
set -euo pipefail

DB="${PGDATABASE:-terraworld}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/postgres}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-postgres/daily}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
DATE="$(date +%Y%m%d-%H%M)"

log() { echo "[pg-backup $(date -u +%FT%TZ)] $*"; }
die() { log "ERROR: $*"; exit 1; }

command -v pg_dump >/dev/null 2>&1 || die "pg_dump not found"
mkdir -p "$BACKUP_DIR"

DUMP="$BACKUP_DIR/${DB}-${DATE}.dump"

# 1) pg_dump (custom format — 빠른 복원 + 선택 복원)
log "dumping ${DB} -> ${DUMP}"
pg_dump -Fc -d "$DB" -f "$DUMP"

# 2) gzip
gzip -f "$DUMP"
ARTIFACT="${DUMP}.gz"

# 3) (선택) GPG 암호화 — recipient 설정 시에만. 미설정이면 평문 gz 업로드.
if [[ -n "${GPG_RECIPIENT:-}" ]] && command -v gpg >/dev/null 2>&1; then
  log "encrypting for ${GPG_RECIPIENT}"
  gpg --batch --yes --encrypt --recipient "$GPG_RECIPIENT" --output "${ARTIFACT}.gpg" "$ARTIFACT"
  rm -f "$ARTIFACT"
  ARTIFACT="${ARTIFACT}.gpg"
else
  log "GPG_RECIPIENT 미설정 — 암호화 skip (평문 gz)"
fi

# 4) S3/R2 업로드 (bucket 설정 시에만)
if [[ -n "$S3_BUCKET" ]] && command -v aws >/dev/null 2>&1; then
  log "uploading -> s3://${S3_BUCKET}/${S3_PREFIX}/"
  aws s3 cp "$ARTIFACT" "s3://${S3_BUCKET}/${S3_PREFIX}/"
else
  log "S3_BUCKET 미설정 또는 aws CLI 부재 — 업로드 skip (로컬 보존만)"
fi

# 5) 로컬 보존 정리 (RETENTION_DAYS 경과분 삭제)
find "$BACKUP_DIR" -name "${DB}-*.dump.gz*" -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true

# 6) (선택) Discord 알림
if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
  curl -fsS -X POST "$DISCORD_WEBHOOK_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"content\":\"✅ pg backup ok: ${DB}-${DATE}\"}" >/dev/null 2>&1 || log "discord 알림 실패(무시)"
fi

log "done: $ARTIFACT"
