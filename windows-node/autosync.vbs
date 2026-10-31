' TerraWorld autosync launcher (Task Scheduler, every 5 min).
' conhost --headless: the console is created without any window, so nothing flashes
' (wscript hide flag alone still lets the bash console show briefly on some setups).
CreateObject("WScript.Shell").Run "conhost.exe --headless ""C:\Program Files\Git\bin\bash.exe"" -l ""/c/Users/jstop/terraworld-node/autosync.sh""", 0, True
