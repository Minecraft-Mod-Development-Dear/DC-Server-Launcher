@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Invoke-Server.ps1" -Mode Normal %*
exit /b %ERRORLEVEL%
