@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Invoke-Server.ps1" -Mode Creative %*
exit /b %ERRORLEVEL%
