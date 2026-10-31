# 윈도우 노드 전체 정지 (감시자 → cloudflared → 앱 순). Mac 노드가 트래픽을 계속 받는다.
Stop-ScheduledTask -TaskName TerraWorldNode -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'supervisor.ps1|run-(backend|frontend|redis)\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" | Where-Object { $_.CommandLine -match 'run terraworld' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Push-Location "$PSScriptRoot\nginx-1.28.0"; & .\nginx.exe -s quit; Pop-Location
foreach ($port in 8080, 3000, 6379) {
  Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }
}
"stopped"
