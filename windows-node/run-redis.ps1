Set-Location "$PSScriptRoot\redis"
& "$PSScriptRoot\redis\redis-server.exe" --bind 127.0.0.1 --port 6379 --protected-mode yes --save '""' *>> "$PSScriptRoot\logs\redis.log"
