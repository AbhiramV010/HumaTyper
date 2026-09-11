@echo off
cd /d "C:\HumaTyper"
rem cmd can't hide its own window, so a throwaway VBS runs npm start hidden.
echo Set WshShell = CreateObject("WScript.Shell") > launch.vbs
echo WshShell.Run "cmd /c npm start", 0, False >> launch.vbs
cscript //nologo launch.vbs
del launch.vbs
exit