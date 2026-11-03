# TerraWorld 윈도우 노드 — 부팅 시 자동 시작 등록 (관리자 PowerShell 로 1회 실행)
#
# 재부팅 후 로그인하지 않아도 노드(감시자 → redis/backend/frontend/nginx/cloudflared)와 자동 동기화가 뜨게 한다.
# - 로그온 유형 S4U: "사용자의 로그온 여부와 관계없이 실행" + 비밀번호 저장 안 함.
#   로컬 프로세스·외부 TCP(Supabase DB, ghcr) 접속에는 충분하다(윈도우 공유 폴더 같은 네트워크 인증만 불가).
# - 트리거: 시스템 시작 시(네트워크 대기 1분 지연). 자동 동기화는 5분 반복도 유지.
# - 감시자는 Global 뮤텍스로 중복 실행을 막으므로, 지금 로그온 세션에서 돌고 있는 감시자와 겹쳐도 안전하다.
$ErrorActionPreference = 'Stop'
$log = 'C:\Users\jstop\terraworld-node\logs\install-boot-start.log'
Start-Transcript -Path $log -Force | Out-Null
try {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) { throw '관리자 권한이 필요합니다. 관리자 PowerShell 에서 실행하세요.' }

  $user = 'jstop'
  $node = 'C:\Users\jstop\terraworld-node'
  $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$user" -LogonType S4U -RunLevel Limited

  # 1) 감시자 — 부팅 1분 후 시작, 실패 시 1분 간격 재시도, 실행 시간 제한 없음
  $nodeTrigger = New-ScheduledTaskTrigger -AtStartup
  $nodeTrigger.Delay = 'PT1M'
  $nodeAction = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//B //Nologo `"$node\supervisor.vbs`""
  $nodeSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName 'TerraWorldNode' -Action $nodeAction -Trigger $nodeTrigger -Principal $principal -Settings $nodeSettings `
    -Description 'TerraWorld 2nd WAS node supervisor (boot start, S4U)' -Force | Out-Null

  # 2) 자동 동기화 — 부팅 3분 후 + 5분마다
  $syncBoot = New-ScheduledTaskTrigger -AtStartup
  $syncBoot.Delay = 'PT3M'
  $syncRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
  $syncAction = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//B //Nologo `"$node\autosync.vbs`""
  $syncSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName 'TerraWorldAutoSync' -Action $syncAction -Trigger @($syncBoot, $syncRepeat) -Principal $principal -Settings $syncSettings `
    -Description 'TerraWorld Windows node autosync (boot + every 5 min, S4U)' -Force | Out-Null

  foreach ($t in 'TerraWorldNode', 'TerraWorldAutoSync') {
    $task = Get-ScheduledTask -TaskName $t
    '{0}: logon={1} triggers={2}' -f $t, $task.Principal.LogonType, (($task.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ',')
  }
  'OK — 다음 재부팅부터 로그인 없이 노드가 시작됩니다.'
}
catch {
  "ERROR: $($_.Exception.Message)"
}
finally {
  Stop-Transcript | Out-Null
}
