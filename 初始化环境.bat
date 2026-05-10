@echo off
setlocal

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

set "EMBED_PYTHON=%ROOT%\runtime\python\python.exe"
set "VENV_DIR=%ROOT%\venv"
set "VENV_PYTHON=%VENV_DIR%\Scripts\python.exe"
set "REQUIREMENTS_FILE=%ROOT%\requirements-portable.txt"
set "APP_DIR=%ROOT%\app\MOSS-TTS"
set "MODEL_PATH=%ROOT%\weights\MOSS-TTS-Local-Transformer"
set "CODEC_LINK=%ROOT%\OpenMOSS-Team\MOSS-Audio-Tokenizer"
set "CODEC_SRC=%ROOT%\weights\MOSS-Audio-Tokenizer"

set "HF_HOME=%ROOT%\cache\huggingface"
set "TRANSFORMERS_CACHE=%ROOT%\cache\huggingface\transformers"
set "MODELSCOPE_CACHE=%ROOT%\cache\modelscope"

echo [INFO] Root: %ROOT%

if not exist "%EMBED_PYTHON%" (
  echo [ERROR] Embedded Python not found: %EMBED_PYTHON%
  echo [ERROR] Please confirm the portable runtime is complete.
  pause
  exit /b 1
)

if not exist "%APP_DIR%" (
  echo [ERROR] App repo not found: %APP_DIR%
  pause
  exit /b 1
)

if not exist "%REQUIREMENTS_FILE%" (
  echo [ERROR] Requirements file not found: %REQUIREMENTS_FILE%
  pause
  exit /b 1
)

if not exist "%HF_HOME%" mkdir "%HF_HOME%"
if not exist "%TRANSFORMERS_CACHE%" mkdir "%TRANSFORMERS_CACHE%"
if not exist "%MODELSCOPE_CACHE%" mkdir "%MODELSCOPE_CACHE%"

if not exist "%VENV_PYTHON%" (
  echo [INFO] Creating venv...
  "%EMBED_PYTHON%" -m venv "%VENV_DIR%"
  if errorlevel 1 (
    echo [ERROR] Failed to create venv.
    pause
    exit /b 1
  )
)

echo [INFO] Upgrading pip/setuptools/wheel...
"%VENV_PYTHON%" -m pip install --upgrade pip setuptools wheel
if errorlevel 1 (
  echo [ERROR] Failed to upgrade packaging tools.
  pause
  exit /b 1
)

echo [INFO] Installing PyTorch CUDA 12.8 packages...
"%VENV_PYTHON%" -m pip install --index-url https://download.pytorch.org/whl/cu128 torch==2.9.1+cu128 torchaudio==2.9.1+cu128
if errorlevel 1 (
  echo [ERROR] Failed to install torch/torchaudio.
  pause
  exit /b 1
)

echo [INFO] Installing Python dependencies...
"%VENV_PYTHON%" -m pip install -r "%REQUIREMENTS_FILE%" --extra-index-url https://download.pytorch.org/whl/cu128
if errorlevel 1 (
  echo [ERROR] Failed to install requirements.
  pause
  exit /b 1
)

echo [INFO] Installing local MOSS-TTS package...
"%VENV_PYTHON%" -m pip install -e "%APP_DIR%"
if errorlevel 1 (
  echo [ERROR] Failed to install local app package.
  pause
  exit /b 1
)

if not exist "%MODEL_PATH%" (
  echo [WARN] Model path not found yet: %MODEL_PATH%
  echo [WARN] WebUI cannot start until model files are present.
) else (
  echo [INFO] Model path found: %MODEL_PATH%
)

if not exist "%CODEC_LINK%" (
  if exist "%CODEC_SRC%" (
    echo [INFO] Creating local codec alias directory...
    powershell -NoLogo -NoProfile -Command "New-Item -ItemType Directory -Force -Path '%ROOT%\OpenMOSS-Team' | Out-Null; if (-not (Test-Path -LiteralPath '%CODEC_LINK%')) { New-Item -ItemType Junction -Path '%CODEC_LINK%' -Target '%CODEC_SRC%' | Out-Null }"
    if errorlevel 1 (
      echo [WARN] Failed to create codec alias automatically.
      echo [WARN] You may need to create this path manually:
      echo [WARN] %CODEC_LINK%  -^>  %CODEC_SRC%
    ) else (
      echo [INFO] Codec alias ready: %CODEC_LINK%
    )
  ) else (
    echo [WARN] Codec source path not found: %CODEC_SRC%
  )
)

echo.
echo [INFO] Initialization finished.
echo [INFO] Next step: double-click "启动 WebUI.bat"
pause
exit /b 0
