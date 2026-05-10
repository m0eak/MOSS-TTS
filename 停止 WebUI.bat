@echo off
setlocal

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "TARGET_PORT="
set "PORT_FILE=%ROOT%\logs\webui.port"
set "TARGET_SCRIPT=%ROOT%\scripts\launch_webui.py"
set "FOUND_PID="

if exist "%PORT_FILE%" (
  set /p TARGET_PORT=<"%PORT_FILE%"
)
if not defined TARGET_PORT set "TARGET_PORT=7860"

for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":%TARGET_PORT% .*LISTENING"') do (
  set "FOUND_PID=%%P"
  goto :have_pid
)

:have_pid
if not defined FOUND_PID (
  echo [INFO] No listening process found on port %TARGET_PORT%.
  pause
  exit /b 0
)

for /f "usebackq delims=" %%L in (`powershell -NoLogo -NoProfile -Command "(Get-CimInstance Win32_Process -Filter \"ProcessId=%FOUND_PID%\").CommandLine"`) do (
  set "CMDLINE=%%L"
)

echo [INFO] Found PID %FOUND_PID% on port %TARGET_PORT%.
echo [INFO] Command: %CMDLINE%

echo %CMDLINE% | find /I "%TARGET_SCRIPT%" >nul
if errorlevel 1 (
  echo [WARN] PID %FOUND_PID% does not look like the MOSS launch_webui.py process.
  echo [WARN] Refusing to stop it automatically.
  pause
  exit /b 1
)

taskkill /PID %FOUND_PID% /T /F
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if "%EXIT_CODE%"=="0" (
  echo [INFO] MOSS-TTS WebUI stopped.
) else (
  echo [ERROR] Failed to stop PID %FOUND_PID%.
)
pause
exit /b %EXIT_CODE%
