#!/usr/bin/env bash
#
# P3-4 (O-DR-001): Redis 7 RDB 스냅샷 백업 → S3/R2 업로드. DR runbook §3.2 실 배선.
#
# 선택 env: REDIS_CLI_ARGS(예: "-h host -p 6379 -a pass"), RDB_PATH(기본 /var/lib/redis/dump.rdb),
#           S3_BUCKET, S3_PREFIX(기본 redis), DISCORD_WEBHOOK_URL.
#
# 주의: Redis 는 rate-limit/광고 카운터 외 비휘발성 데이터 없음 — 1일 손실 허용(runbook §3.3).
set -euo pipefail

REDIS_CLI_ARGS="${REDIS_CLI_ARGS:-}"
RDB_PATH="${RDB_PATH:-/var/lib/redis/dump.rdb}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-redis}"
DATE="$(date +%Y%m%d-%H%M)"

log() { echo "[redis-backup $(date -u +%FT%TZ)] $*"; }
die() { log "ERROR: $*"; exit 1; }

command -v redis-cli >/dev/null 2>&1 || die "redis-cli not found"

# 1) BGSAVE 트리거 + 완료 대기 (rdb_last_save_time 변화로 확인)
# shellcheck disable=SC2086
BEFORE="$(redis-cli $REDIS_CLI_ARGS LASTSAVE)"
log "triggering BGSAVE"
# shellcheck disable=SC2086
redis-cli $REDIS_CLI_ARGS BGSAVE >/dev/null

for _ in $(seq 1 30); do
  sleep 1
  # shellcheck disable=SC2086
  AFTER="$(redis-cli $REDIS_CLI_ARGS LASTSAVE)"
  [[ "$AFTER" != "$BEFORE" ]] && { log "BGSAVE complete"; break; }
done

[[ -f "$RDB_PATH" ]] || die "RDB 파일 부재: $RDB_PATH"

# 2) S3/R2 업로드
if [[ -n "$S3_BUCKET" ]] && command -v aws >/dev/null 2>&1; then
  log "uploading -> s3://${S3_BUCKET}/${S3_PREFIX}/${DATE}.rdb"
  aws s3 cp "$RDB_PATH" "s3://${S3_BUCKET}/${S3_PREFIX}/${DATE}.rdb"
else
  log "S3_BUCKET 미설정 또는 aws CLI 부재 — 업로드 skip"
fi

# 3) (선택) Discord 알림
if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
  curl -fsS -X POST "$DISCORD_WEBHOOK_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"content\":\"✅ redis backup ok: ${DATE}\"}" >/dev/null 2>&1 || log "discord 알림 실패(무시)"
fi

log "done"
