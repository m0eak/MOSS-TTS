@echo off
setlocal EnableDelayedExpansion

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "PYTHON_EXE=%ROOT%\venv\Scripts\python.exe"
set "APP_SCRIPT=%ROOT%\scripts\launch_webui.py"
set "MODEL_PATH=%ROOT%\weights\MOSS-TTS-Local-Transformer"
set "HF_HOME=%ROOT%\cache\huggingface"
set "TRANSFORMERS_CACHE=%ROOT%\cache\huggingface\transformers"
set "MODELSCOPE_CACHE=%ROOT%\cache\modelscope"
set "PORT_FILE=%ROOT%\logs\webui.port"
set "PORT_MIN=7860"
set "PORT_MAX=7870"
set "SELECTED_PORT="

if not exist "%PYTHON_EXE%" (
  echo [ERROR] Python not found: %PYTHON_EXE%
  pause
  exit /b 1
)

if not exist "%APP_SCRIPT%" (
  echo [ERROR] launch_webui.py not found: %APP_SCRIPT%
  pause
  exit /b 1
)

if not exist "%MODEL_PATH%" (
  echo [ERROR] Model path not found: %MODEL_PATH%
  pause
  exit /b 1
)

if not exist "%HF_HOME%" mkdir "%HF_HOME%"
if not exist "%TRANSFORMERS_CACHE%" mkdir "%TRANSFORMERS_CACHE%"
if not exist "%MODELSCOPE_CACHE%" mkdir "%MODELSCOPE_CACHE%"
if not exist "%ROOT%\logs" mkdir "%ROOT%\logs"

for /l %%P in (%PORT_MIN%,1,%PORT_MAX%) do (
  netstat -ano | findstr /R /C:":%%P .*LISTENING" >nul
  if errorlevel 1 (
    set "SELECTED_PORT=%%P"
    goto :port_found
  )
)

:port_found
if not defined SELECTED_PORT (
  echo [ERROR] No available port found in range %PORT_MIN%-%PORT_MAX%.
  pause
  exit /b 1
)

> "%PORT_FILE%" echo !SELECTED_PORT!

echo [INFO] Starting MOSS-TTS WebUI...
echo [INFO] Root: %ROOT%
echo [INFO] Model: %MODEL_PATH%
echo [INFO] Port: !SELECTED_PORT!
echo [INFO] URL: http://127.0.0.1:!SELECTED_PORT!
echo.

"%PYTHON_EXE%" "%APP_SCRIPT%" --model_path "%MODEL_PATH%" --device cuda:0 --port !SELECTED_PORT!

set "EXIT_CODE=%ERRORLEVEL%"
echo.
echo [INFO] WebUI exited with code %EXIT_CODE%.
pause
exit /b %EXIT_CODE%
