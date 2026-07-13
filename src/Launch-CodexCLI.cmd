@echo off
cd /d "%~dp0"
wscript.exe "%~dp0CodexCLI-Launcher.vbs"
exit /b %ERRORLEVEL%
