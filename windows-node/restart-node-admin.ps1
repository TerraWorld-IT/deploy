# 관리자 권한으로 실행: 노드 앱 전체 정지 후 TerraWorldNode 작업 재시작 (app.env 재적용)
$log = 'C:\Users\jstop\terraworld-node\logs\restart-node-admin.log'
Start-Transcript -Path $log -Force | Out-Null
Stop-ScheduledTask TerraWorldNode -ErrorAction SilentlyContinue
$ports = 3000, 8080
foreach ($p in $ports) {
  Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | % { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue; "killed port $p pid $($_.OwningProcess)" }
}
Get-Process nginx, cloudflared -ErrorAction SilentlyContinue | % { Stop-Process -Id $_.Id -Force; "killed $($_.Name) $($_.Id)" }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ? { $_.CommandLine -match 'supervisor\.ps1|run-(backend|frontend|nginx)\.ps1' -and $_.ProcessId -ne $PID } | % { Stop-Process -Id $_.ProcessId -Force; "killed supervisor/run $($_.ProcessId)" }
# 감시자 오작동으로 쌓인 창 없는 콘솔(conhost --headless) 정리 — 사용자 터미널은 건드리지 않는다
Get-CimInstance Win32_Process -Filter "Name='conhost.exe'" | ? { $_.CommandLine -match '--headless' -and $_.CommandLine -match 'nginx|run-(redis|backend|frontend)|cloudflared' } | % { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
"nginx left: $(@(Get-Process nginx -ErrorAction SilentlyContinue).Count), conhost left: $(@(Get-Process conhost -ErrorAction SilentlyContinue).Count)"
Start-Sleep 3
Start-ScheduledTask TerraWorldNode
"restarted TerraWorldNode at $(Get-Date -Format s)"
Stop-Transcript | Out-Null
