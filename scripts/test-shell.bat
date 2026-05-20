@echo off
setlocal
cd /D "%~dp0\.."
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-shell.ps1 %*
exit /b %ERRORLEVEL%
