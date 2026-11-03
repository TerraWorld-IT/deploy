#!/bin/bash
# 윈도우 노드 frontend 를 지정 digest 로 교체한다. 사용: ./update-frontend.sh sha256:<digest>
# 롤백: app/frontend.digest.prev 의 digest 로 다시 실행.
#
# ⚠️ 이미지의 심볼릭 링크는 디렉터리 정션(절대 경로)으로 복원되므로 추출 후 디렉터리를
#    옮기면 정션이 끊긴다 → 반드시 최종 경로(app/frontend)에 직접 추출한다.
#    교체 동안 윈도우 frontend 가 잠시 내려가지만 트래픽은 Mac 커넥터가 받는다.
set -euo pipefail
D="$HOME/terraworld-node"
DIGEST="${1:?usage: update-frontend.sh sha256:<digest>}"
IMG="ghcr.io/terraworld-it/terraworld-frontend@$DIGEST"
cd "$D"
rm -f frontend.tar
bin/crane.exe export "$IMG" frontend.tar            # 다운로드 먼저(실패 시 기존 버전 유지)
# 감시자 일시정지 → frontend 정지
powershell -NoProfile -Command "Stop-ScheduledTask -TaskName TerraWorldNode -ErrorAction SilentlyContinue; Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { \$_.ProcessId -ne \$PID -and \$_.CommandLine -match 'supervisor.ps1|run-frontend.ps1' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }; Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id \$_.OwningProcess -Force -ErrorAction SilentlyContinue }; exit 0" || true
sleep 2
[ -f app/frontend.digest ] && cp app/frontend.digest app/frontend.digest.prev
cmd //c "rmdir /s /q app\\frontend" 2>/dev/null || true   # 정션은 링크만 제거(대상 미추적)
mkdir -p app/frontend
python tmp-extract.py frontend.tar app/frontend
S=app/frontend/.output/server/node_modules/sharp
rm -rf "$S/build" "$S/vendor" && cp -r tmp-sharp/node_modules/sharp/build tmp-sharp/node_modules/sharp/vendor "$S/"
(cd app/frontend/.output/server && "$D/node-v20.20.2-win-x64/node.exe" -e "require('./node_modules/sharp')({create:{width:2,height:2,channels:3,background:'red'}}).png().toBuffer().then(()=>console.log('sharp OK'))")
echo "$DIGEST" > app/frontend.digest
rm -f frontend.tar
powershell -NoProfile -Command "Start-ScheduledTask -TaskName TerraWorldNode"   # 감시자가 frontend 재기동
echo "swapped to $DIGEST (rollback: ./update-frontend.sh \$(cat app/frontend.digest.prev))"
