@echo off
rem ============================================================
rem  Double-click entry point for the LiteLLM gateway console.
rem
rem  Content is ASCII on purpose: cmd.exe reads .cmd files with the
rem  ANSI codepage (GBK here), so Chinese text in this file would be
rem  garbled. All Chinese lives in gateway-menu.ps1, which PowerShell 7
rem  reads as UTF-8.
rem ============================================================

chcp 65001 >nul
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"

if not exist "%PWSH%" (
  echo.
  echo [!] PowerShell 7 not found at: %PWSH%
  echo     install it from https://aka.ms/powershell
  echo.
  pause
  exit /b 1
)

"%PWSH%" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0gateway-menu.ps1"

if errorlevel 1 (
  echo.
  echo [!] the console exited with an error. See the message above.
  pause
)
