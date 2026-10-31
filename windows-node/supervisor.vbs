' TerraWorld node supervisor launcher (Task Scheduler, at logon) - headless console, no window.
CreateObject("WScript.Shell").Run "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""C:\Users\jstop\terraworld-node\supervisor.ps1""", 0, False
