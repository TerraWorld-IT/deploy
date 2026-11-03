. "$PSScriptRoot\load-env.ps1"
$env:HOST = '127.0.0.1'; $env:PORT = '3000'; $env:NODE_ENV = 'production'
Set-Location "$PSScriptRoot\app\frontend"
$p = Start-Process -FilePath "$PSScriptRoot\node-v20.20.2-win-x64\node.exe" -ArgumentList '.output\server\index.mjs' -NoNewWindow -PassThru `
  -RedirectStandardOutput "$PSScriptRoot\logs\frontend.out.log" -RedirectStandardError "$PSScriptRoot\logs\frontend.err.log"
$p.WaitForExit()
exit $p.ExitCode
