#!/bin/bash
# 윈도우 노드 자동 동기화 — 작업 스케줄러 "TerraWorldAutoSync" 가 5분마다 실행한다.
# ghcr latest digest 가 바뀌면 sync-node.sh(드레인 → 교체 → 로컬 검증 → 복귀)로 맞춘다.
#
# - Mac 먼저: 새 digest 를 처음 본 뒤 SETTLE_SEC 가 지나야 적용한다(CI push → Mac 자동배포·Flyway 완료 대기).
# - 실패 시: 이전 digest 로 롤백하고 그 digest 쌍을 failed 로 기록해 재시도하지 않는다(새 digest 가 나오면 다시 시도).
# - 중지: 작업 스케줄러에서 TerraWorldAutoSync 비활성화, 또는 state/autosync.disabled 파일 생성.
set -uo pipefail
D="$HOME/terraworld-node"
S="$D/state"; mkdir -p "$S" "$D/logs"
LOG="$D/logs/autosync.log"
SETTLE_SEC=${AUTOSYNC_SETTLE_SEC:-180}
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
notify() { [ -x "$HOME/bin/bus-send" ] && echo "$2" | "$HOME/bin/bus-send" "$1" >/dev/null 2>&1 || true; }

[ -f "$S/autosync.disabled" ] && exit 0
# 중복 실행 방지(mkdir 은 원자적). 잠금을 쥔 프로세스가 이미 죽었거나(강제 종료 잔재)
# 30분이 넘은 잠금은 회수한다.
LOCK="$S/autosync.lockdir"
if ! mkdir "$LOCK" 2>/dev/null; then
  holder=$(cat "$LOCK/pid" 2>/dev/null)
  if { [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; } || [ -z "$holder" ] || [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    rm -rf "$LOCK" && mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
date '+%F %T' > "$S/autosync.last"   # 하트비트(마지막 확인 시각)

cd "$D"
BE_NEW=$(bin/crane.exe digest ghcr.io/terraworld-it/terraworld-backend:latest 2>>"$LOG") || { log "digest 조회 실패(backend) — ghcr 인증 확인"; exit 0; }
FE_NEW=$(bin/crane.exe digest ghcr.io/terraworld-it/terraworld-frontend:latest 2>>"$LOG") || { log "digest 조회 실패(frontend)"; exit 0; }
BE_CUR=$(cat app/backend.digest 2>/dev/null); FE_CUR=${AUTOSYNC_FAKE_FE_CUR:-$(cat app/frontend.digest 2>/dev/null)}
PAIR="$BE_NEW $FE_NEW"

if [ "$BE_NEW" = "$BE_CUR" ] && [ "$FE_NEW" = "$FE_CUR" ]; then rm -f "$S/pending"; exit 0; fi
grep -qxF "$PAIR" "$S/failed" 2>/dev/null && exit 0

# 안정화 대기: 같은 쌍을 처음 본 시각 기록
now=$(date +%s)
if [ "$(cut -d' ' -f1,2 "$S/pending" 2>/dev/null)" != "$PAIR" ]; then
  echo "$PAIR $now" > "$S/pending"; log "새 이미지 감지 be=${BE_NEW:7:12} fe=${FE_NEW:7:12} — ${SETTLE_SEC}s 대기"; exit 0
fi
first=$(cut -d' ' -f3 "$S/pending"); [ $((now - first)) -lt $SETTLE_SEC ] && exit 0

[ -n "${AUTOSYNC_DRYRUN:-}" ] && { log "[dry-run] 동기화 실행 예정 be=${BE_NEW:7:12} fe=${FE_NEW:7:12}"; exit 0; }
log "동기화 시작 be ${BE_CUR:7:12}→${BE_NEW:7:12} fe ${FE_CUR:7:12}→${FE_NEW:7:12}"
if bash "$D/sync-node.sh" "$BE_NEW" "$FE_NEW" >> "$LOG" 2>&1; then
  rm -f "$S/pending"; log "동기화 완료"
  notify "[auto] 윈도우 자동 동기화 완료" "backend ${BE_NEW:7:12} / frontend ${FE_NEW:7:12} 로 교체(드레인 후). 로컬 검증 통과, 커넥터 복귀."
else
  log "동기화 실패 — 이전 버전으로 롤백"
  echo "$PAIR" >> "$S/failed"; rm -f "$S/pending"
  if bash "$D/sync-node.sh" "$BE_CUR" "$FE_CUR" >> "$LOG" 2>&1; then
    log "롤백 완료"; notify "[auto] 윈도우 동기화 실패 → 롤백" "새 be ${BE_NEW:7:12} / fe ${FE_NEW:7:12} 로컬 검증 실패. 이전 버전으로 롤백, 커넥터 복귀. logs/autosync.log 확인 필요."
  else
    log "롤백도 실패 — 윈도우 커넥터 내려간 상태(Mac 단독 서빙)"
    notify "[auto] ⚠️ 윈도우 동기화·롤백 실패" "윈도우 cloudflared 미연결 상태(Mac 단독 서빙). 수동 조치 필요: logs/autosync.log"
  fi
fi
