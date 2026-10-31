#!/bin/bash
# 윈도우 노드를 지정 digest 쌍으로 동기화한다 (트래픽 드레인 → backend → frontend → 검증 → 복귀).
# 사용: ./sync-node.sh <backend sha256:…> <frontend sha256:…>
#
# Cloudflare 는 오리진 헬스체크를 하지 않으므로, 커넥터가 붙은 채로 앱을 내리면 이 노드로 간 요청이
# 502 가 된다. 그래서 cloudflared 를 먼저 내려(Mac 단독 서빙) 교체하고, 로컬 검증 후 다시 붙인다.
set -euo pipefail
D="$HOME/terraworld-node"
BE="${1:?usage: sync-node.sh <backend digest> <frontend digest>}"
FE="${2:?usage: sync-node.sh <backend digest> <frontend digest>}"
cd "$D"
ps() { powershell -NoProfile -Command "$1; exit 0" || true; }
H='Host: terraworld.web-qplay.kr'

echo "[1/6] 이미지 다운로드"
bin/crane.exe export "ghcr.io/terraworld-it/terraworld-backend@$BE" backend.tar
bin/crane.exe export "ghcr.io/terraworld-it/terraworld-frontend@$FE" frontend.tar
rm -rf app/backend.new && mkdir -p app/backend.new && tar -xf backend.tar -C app/backend.new --strip-components=1 app/app.jar
[ -s app/backend.new/app.jar ]

echo "[2/6] 드레인: 감시자·cloudflared 정지"
ps "Stop-ScheduledTask -TaskName TerraWorldNode -ErrorAction SilentlyContinue; Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { \$_.ProcessId -ne \$PID -and \$_.CommandLine -match 'supervisor.ps1|run-frontend.ps1|run-backend.ps1' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }; Get-CimInstance Win32_Process -Filter \"Name='cloudflared.exe'\" | Where-Object { \$_.CommandLine -match 'run terraworld' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }"
sleep 5

echo "[3/6] backend 교체"
ps "Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id \$_.OwningProcess -Force -ErrorAction SilentlyContinue }"
sleep 2
[ -f app/backend.digest ] && cp app/backend.digest app/backend.digest.prev
mv -f app/backend/app.jar app/backend/app.jar.prev 2>/dev/null || true
mv app/backend.new/app.jar app/backend/app.jar && rmdir app/backend.new
echo "$BE" > app/backend.digest

echo "[4/6] frontend 교체"
ps "Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id \$_.OwningProcess -Force -ErrorAction SilentlyContinue }"
sleep 2
[ -f app/frontend.digest ] && cp app/frontend.digest app/frontend.digest.prev
cmd //c "rmdir /s /q app\\frontend" 2>/dev/null || true
mkdir -p app/frontend
python tmp-extract.py frontend.tar app/frontend        # 정션은 최종 경로에 직접 생성해야 한다
S=app/frontend/.output/server/node_modules/sharp
rm -rf "$S/build" "$S/vendor" && cp -r tmp-sharp/node_modules/sharp/build tmp-sharp/node_modules/sharp/vendor "$S/"
echo "$FE" > app/frontend.digest
rm -f backend.tar frontend.tar

echo "[5/6] 앱 기동(cloudflared 없이) + 로컬 검증"
ps "Start-Process conhost.exe -ArgumentList '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"$(cygpath -w "$D")\\run-backend.ps1\"' -WindowStyle Hidden"
ps "Start-Process conhost.exe -ArgumentList '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"$(cygpath -w "$D")\\run-frontend.ps1\"' -WindowStyle Hidden"
ok=0
for i in $(seq 1 60); do
  b=$(curl -s -m 3 http://127.0.0.1:8080/actuator/health || true)
  f=$(curl -s -o /dev/null -w '%{http_code}' -m 5 -H "$H" http://127.0.0.1:18090/auth/login || true)
  if echo "$b" | grep -q UP && [ "$f" = 200 ]; then ok=1; break; fi
  sleep 3
done
[ "$ok" = 1 ] || { echo "로컬 검증 실패 — cloudflared 를 붙이지 않고 중단 (Mac 단독 서빙 유지)"; exit 1; }
echo "  backend UP, /auth/login 200, / $(curl -s -o /dev/null -w '%{http_code}' -H "$H" http://127.0.0.1:18090/)"

echo "[6/6] 복귀: 감시자 재개(cloudflared 재연결)"
ps "Start-ScheduledTask -TaskName TerraWorldNode"
echo "synced backend=$BE frontend=$FE"
