. "$PSScriptRoot\load-env.ps1"
$env:SERVER_ADDRESS = '127.0.0.1'   # 외부 노출 금지 — nginx 만 접근
Set-Location "$PSScriptRoot\app\backend"
$javaArgs = @('-Xms256m','-Xmx512m','-XX:MaxMetaspaceSize=256m','-XX:+ExitOnOutOfMemoryError','"-Duser.timezone=UTC"','"-Dfile.encoding=UTF-8"','-jar','app.jar')
$p = Start-Process -FilePath "$PSScriptRoot\jdk-21.0.12.1+1\bin\java.exe" -ArgumentList $javaArgs -NoNewWindow -PassThru `
  -RedirectStandardOutput "$PSScriptRoot\logs\backend.out.log" -RedirectStandardError "$PSScriptRoot\logs\backend.err.log"
$p.WaitForExit()
exit $p.ExitCode
