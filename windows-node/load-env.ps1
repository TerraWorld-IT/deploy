# app.env(KEY=VALUE) 를 현재 프로세스 환경변수로 로드
param([string]$File = "$PSScriptRoot\app.env")
Get-Content $File | Where-Object { $_ -match '^[A-Za-z_][A-Za-z0-9_]*=' } | ForEach-Object {
  $k, $v = $_ -split '=', 2
  [Environment]::SetEnvironmentVariable($k, $v, 'Process')
}
