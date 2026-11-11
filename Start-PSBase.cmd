@echo off
setlocal
where pwsh >nul 2>nul
if errorlevel 1 (
    echo PowerShell 7 was not found.
    echo Install PowerShell 7 from https://aka.ms/powershell
    pause
    exit /b 1
)
pwsh -NoProfile -STA -File "%~dp0PS-Base-GUI.ps1" %*
if errorlevel 1 (
    echo.
    echo PS Base exited with an error.
    pause
)
