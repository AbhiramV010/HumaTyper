@echo off
cd /d "C:\Abhiram\Projects\AutoTyper"
echo Set WshShell = CreateObject("WScript.Shell") > launch.vbs
echo WshShell.Run "cmd /c npm start", 0, False >> launch.vbs
cscript //nologo launch.vbs
del launch.vbs
exit