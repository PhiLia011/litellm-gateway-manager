@echo off
rem ============================================================
rem  LiteLLM gateway launcher  (127.0.0.1:4000)
rem
rem  !! THIS FILE MUST STAY 7-BIT ASCII !!
rem  cmd.exe reads .cmd files using the ANSI codepage (GBK on a
rem  Chinese Windows). A UTF-8 Chinese character here gets mangled
rem  and can even swallow the line break, turning the script into
rem  garbage commands such as:
rem      'ot' is not recognized as an internal or external command
rem  Chinese documentation lives in README.md and in gateway-menu.ps1
rem  (the latter runs under PowerShell 7, which does read UTF-8).
rem
rem  Used by the "LiteLLM-Gateway" scheduled task (hidden, via
rem  run-hidden.vbs) and by hand.
rem
rem  Required User-scope env vars (inherited from the user profile):
rem    DEEPSEEK_API_KEY / ZAI_API_KEY / DASHSCOPE_API_KEY / ...
rem    LITELLM_MASTER_KEY
rem    PYTHONUTF8=1                         Python must read UTF-8 config.yaml
rem    LITELLM_LOCAL_MODEL_COST_MAP=True    skip the unreachable GitHub fetch
rem
rem  NOTE: there is deliberately NO "port already listening -> skip" guard.
rem  It caused silent no-op starts: the menu kills the old process first, but
rem  the socket takes a moment to be released, so the guard kept seeing a
rem  stale listener and skipped launching -- which looked like "restart
rem  failed" with nothing in any log. A double start is harmless: the second
rem  instance just fails to bind and exits.
rem ============================================================

setlocal
rem ROOT = this script's own folder (%~dp0 already ends with a backslash),
rem so the whole folder can live anywhere.
set "ROOT=%~dp0"
set "EXE=%USERPROFILE%\.local\bin\litellm.exe"
set "CFG=%ROOT%config.yaml"
set "LOG=%ROOT%logs\gateway.log"
set "LAUNCHLOG=%ROOT%logs\launcher.log"

if not exist "%ROOT%logs" mkdir "%ROOT%logs"

if not exist "%EXE%" (
  echo [ERROR] litellm.exe not found: %EXE% 1>&2
  echo         run:  uv tool install "litellm[proxy]" 1>&2
  exit /b 1
)

rem rotate the log at ~5 MB so it cannot grow forever
if exist "%LOG%" for %%A in ("%LOG%") do if %%~zA GTR 5242880 move /y "%LOG%" "%LOG%.1" >nul

rem If a previous instance still holds the log handle, redirecting into it
rem fails -- and a failed redirection means litellm never starts at all.
rem Fall back to a timestamped log instead of dying silently.
( >> "%LOG%" echo. ) 2>nul
if errorlevel 1 set "LOG=%ROOT%\logs\gateway-%RANDOM%.log"

echo [%DATE% %TIME%] starting gateway on 127.0.0.1:4000 >> "%LAUNCHLOG%"

"%EXE%" --config "%CFG%" --host 127.0.0.1 --port 4000 >> "%LOG%" 2>&1
exit /b %ERRORLEVEL%
