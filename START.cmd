@echo off
chcp 65001 >nul
cd /d "%~dp0"
rem Prybraty poznachku "zavantazheno z internetu", shchob Windows ne blokuvav skrypt
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath (Get-Location) | Unblock-File" >/dev/null 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
