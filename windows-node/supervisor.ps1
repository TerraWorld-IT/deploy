# TerraWorld 윈도우 노드 감시자 — 30초마다 각 구성요소를 확인하고 죽어 있으면 다시 띄운다.
# 작업 스케줄러 "TerraWorldNode" (로그온 시) 가 실행. 중지: 작업 종료 + stop-all.ps1
$ErrorActionPreference = 'SilentlyContinue'
$d = $PSScriptRoot
$log = "$d\logs\supervisor.log"
function Log($m) { "$(Get-Date -Format s) $m" | Out-File -Append -Encoding utf8 $log }

# Get-NetTCPConnection(CIM)은 S4U 세션에서 가끔 빈 결과를 돌려줘(2026-10-29~31) 멀쩡한 구성요소를
# 계속 재기동하고 nginx 가 수백 개 쌓였다. 실제로 접속해 보는 방식으로 확인한다.
function Listening($port) {
  $c = New-Object System.Net.Sockets.TcpClient
  try { $c.ConnectAsync('127.0.0.1', $port).Wait(2000) -and $c.Connected } catch { $false } finally { $c.Close() }
}
function StartPs($script) {
  # conhost --headless: 콘솔을 창 없이 만든다(-WindowStyle Hidden 만으로는 잠깐 깜빡일 수 있음)
  Start-Process conhost.exe -ArgumentList "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$d\$script`"" -WindowStyle Hidden
}

# 중복 실행 방지
$mutex = New-Object System.Threading.Mutex($false, 'Global\TerraWorldNodeSupervisor')
if (-not $mutex.WaitOne(0)) { exit 0 }
Log 'supervisor start'

while ($true) {
  if (-not (Listening 6379))  { Log 'start redis';    StartPs 'run-redis.ps1' }
  if (-not (Listening 8080))  { Log 'start backend';  StartPs 'run-backend.ps1'; Start-Sleep 25 }
  if (-not (Listening 3000))  { Log 'start frontend'; StartPs 'run-frontend.ps1' }
  if (-not (Listening 18090) -and -not (Get-Process nginx -ErrorAction SilentlyContinue)) { Log 'start nginx';   Start-Process conhost.exe -ArgumentList "--headless `"$d\nginx-1.28.0\nginx.exe`"" -WorkingDirectory "$d\nginx-1.28.0" -WindowStyle Hidden }
  $cf = Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" | Where-Object { $_.CommandLine -match 'run terraworld' }
  if (-not $cf) {
    Log 'start cloudflared'
    Start-Process conhost.exe -ArgumentList "--headless cloudflared.exe tunnel --config `"$env:USERPROFILE\.cloudflared\config.yml`" --logfile `"$d\logs\cloudflared.log`" run terraworld" -WindowStyle Hidden
  }
  Start-Sleep 30
}
