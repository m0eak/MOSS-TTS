@echo off
setlocal EnableExtensions

set "SELF_PATH=%~f0"
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

set "MODE=%~1"
set "WRITE_ONLY=0"
if /I "%MODE%"=="--write-only" set "WRITE_ONLY=1"

rem Pin bootstrap source to the fork main branch so deployment stays stable
rem even if upstream OpenMOSS/MOSS-TTS changes in incompatible ways.
set "PYTHON_VERSION=3.12.10"
set "PYTHON_NUGET_URL=https://www.nuget.org/api/v2/package/python/3.12.10"
set "UPSTREAM_REPO_URL=https://github.com/m0eak/MOSS-TTS.git"
set "UPSTREAM_REPO_BRANCH=main"
set "TORCH_INDEX_URL=https://download.pytorch.org/whl/cu128"
set "MODEL_TTS_ID=openmoss/MOSS-TTS-Local-Transformer"
set "MODEL_CODEC_ID=openmoss/MOSS-Audio-Tokenizer"

set "APP_PARENT=%ROOT%\app"
set "APP_DIR=%APP_PARENT%\MOSS-TTS"
set "SCRIPTS_DIR=%ROOT%\scripts"
set "DOCS_DIR=%ROOT%\docs"
set "RUNTIME_DIR=%ROOT%\runtime"
set "PYTHON_DIR=%RUNTIME_DIR%\python"
set "PYTHON_EXE=%PYTHON_DIR%\python.exe"
set "PYTHON_NUGET_PACKAGE=%RUNTIME_DIR%\python.%PYTHON_VERSION%.nupkg"
set "PYTHON_NUGET_ZIP=%RUNTIME_DIR%\python.%PYTHON_VERSION%.zip"
set "PYTHON_EXTRACT_DIR=%RUNTIME_DIR%\python-package"
set "VENV_DIR=%ROOT%\venv"
set "VENV_PYTHON=%VENV_DIR%\Scripts\python.exe"
set "WEIGHTS_DIR=%ROOT%\weights"
set "MODEL_PATH=%WEIGHTS_DIR%\MOSS-TTS-Local-Transformer"
set "CODEC_SRC=%WEIGHTS_DIR%\MOSS-Audio-Tokenizer"
set "OPENMOSS_DIR=%ROOT%\OpenMOSS-Team"
set "CODEC_LINK=%OPENMOSS_DIR%\MOSS-Audio-Tokenizer"
set "OUTPUTS_DIR=%ROOT%\outputs"
set "SRT_OUTPUT_DIR=%OUTPUTS_DIR%\srt_jobs"
set "DATA_DIR=%ROOT%\data"
set "ROLES_DIR=%DATA_DIR%\roles"
set "CACHE_DIR=%ROOT%\cache"
set "HF_HOME=%CACHE_DIR%\huggingface"
set "TRANSFORMERS_CACHE=%HF_HOME%\transformers"
set "MODELSCOPE_CACHE=%CACHE_DIR%\modelscope"
set "LOGS_DIR=%ROOT%\logs"
set "REQUIREMENTS_FILE=%ROOT%\requirements-portable.txt"
set "ROOT_START_BAT=%ROOT%\start_webui.bat"
set "ROOT_STOP_BAT=%ROOT%\stop_webui.bat"
set "WRAPPER_PY=%SCRIPTS_DIR%\launch_webui.py"

echo [INFO] Bootstrap root: %ROOT%
echo [INFO] Upstream repo : %UPSTREAM_REPO_URL% [%UPSTREAM_REPO_BRANCH%]
if "%WRITE_ONLY%"=="1" echo [INFO] Running in write-only validation mode.

call :ensure_dir "%APP_PARENT%"
if errorlevel 1 goto :fatal
call :ensure_dir "%SCRIPTS_DIR%"
if errorlevel 1 goto :fatal
call :ensure_dir "%DOCS_DIR%"
if errorlevel 1 goto :fatal
call :ensure_dir "%RUNTIME_DIR%"
if errorlevel 1 goto :fatal
call :ensure_dir "%WEIGHTS_DIR%"
if errorlevel 1 goto :fatal
call :ensure_dir "%OUTPUTS_DIR%"
if errorlevel 1 goto :fatal
call :ensure_dir "%SRT_OUTPUT_DIR%"
if errorlevel 1 goto :fatal
call :ensure_dir "%DATA_DIR%"
if errorlevel 1 goto :fatal
call :ensure_dir "%ROLES_DIR%"
if errorlevel 1 goto :fatal
call :ensure_dir "%CACHE_DIR%"
if errorlevel 1 goto :fatal
call :ensure_dir "%HF_HOME%"
if errorlevel 1 goto :fatal
call :ensure_dir "%TRANSFORMERS_CACHE%"
if errorlevel 1 goto :fatal
call :ensure_dir "%MODELSCOPE_CACHE%"
if errorlevel 1 goto :fatal
call :ensure_dir "%LOGS_DIR%"
if errorlevel 1 goto :fatal
call :ensure_dir "%OPENMOSS_DIR%"
if errorlevel 1 goto :fatal

call :write_wrapper
if errorlevel 1 goto :fatal
call :write_root_init_wrapper
if errorlevel 1 goto :fatal
call :write_root_start_cn_wrapper
if errorlevel 1 goto :fatal
call :write_root_stop_cn_wrapper
if errorlevel 1 goto :fatal
call :write_root_start_bat
if errorlevel 1 goto :fatal
call :write_root_stop_bat
if errorlevel 1 goto :fatal
call :write_docs_readme
if errorlevel 1 goto :fatal

if "%WRITE_ONLY%"=="1" goto :write_only_done

call :install_local_python
if errorlevel 1 goto :fatal
call :create_venv
if errorlevel 1 goto :fatal
call :clone_upstream_repo
if errorlevel 1 goto :fatal
call :install_packages
if errorlevel 1 goto :fatal
call :download_models
if errorlevel 1 goto :fatal
call :create_codec_alias
if errorlevel 1 goto :fatal
call :export_requirements
if errorlevel 1 goto :fatal

echo.
echo [INFO] Initialization finished.
echo [INFO] Next step: double-click "启动 WebUI.bat"
echo [INFO] WebUI URL: http://127.0.0.1:7860
if "%WRITE_ONLY%"=="1" exit /b 0
pause
exit /b 0

:write_only_done
echo.
echo [INFO] Write-only generation finished.
echo [INFO] Generated wrapper: %WRAPPER_PY%
echo [INFO] Generated launchers under: %ROOT%
exit /b 0

:fatal
echo.
echo [FATAL] Initialization failed. See the error messages above.
echo [FATAL] If you launched this by double-clicking, the window is being kept open for inspection.
pause
exit /b 1

:ensure_dir
if not exist "%~1" mkdir "%~1"
if errorlevel 1 (
  echo [ERROR] Failed to create directory: %~1
  exit /b 1
)
exit /b 0

:install_local_python
if exist "%PYTHON_EXE%" (
  echo [INFO] Local Python already exists: %PYTHON_EXE%
  exit /b 0
)

if exist "%PYTHON_NUGET_PACKAGE%" (
  echo [INFO] Reusing existing Python runtime package: %PYTHON_NUGET_PACKAGE%
) else (
  echo [INFO] Downloading Python %PYTHON_VERSION% runtime package...
  powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%PYTHON_NUGET_URL%' -OutFile '%PYTHON_NUGET_PACKAGE%'"
  if errorlevel 1 (
    echo [ERROR] Failed to download Python runtime package.
    exit /b 1
  )
)

echo [INFO] Extracting local Python runtime...
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Copy-Item -LiteralPath '%PYTHON_NUGET_PACKAGE%' -Destination '%PYTHON_NUGET_ZIP%' -Force; if (Test-Path -LiteralPath '%PYTHON_EXTRACT_DIR%') { Remove-Item -LiteralPath '%PYTHON_EXTRACT_DIR%' -Recurse -Force }; Expand-Archive -LiteralPath '%PYTHON_NUGET_ZIP%' -DestinationPath '%PYTHON_EXTRACT_DIR%' -Force"
if errorlevel 1 (
  echo [ERROR] Failed to extract Python runtime package.
  exit /b 1
)

if not exist "%PYTHON_EXTRACT_DIR%\tools\python.exe" (
  echo [ERROR] Extracted runtime does not contain tools\python.exe
  exit /b 1
)

robocopy "%PYTHON_EXTRACT_DIR%\tools" "%PYTHON_DIR%" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS >nul
set "ROBOCOPY_EXIT=%ERRORLEVEL%"
if %ROBOCOPY_EXIT% GEQ 8 (
  echo [ERROR] Failed to copy extracted Python runtime. robocopy exit=%ROBOCOPY_EXIT%
  exit /b 1
)

echo [INFO] Local Python ready: %PYTHON_EXE%
exit /b 0

:create_venv
if exist "%VENV_PYTHON%" (
  echo [INFO] Local venv already exists: %VENV_DIR%
  exit /b 0
)

echo [INFO] Creating local venv...
"%PYTHON_EXE%" -m venv "%VENV_DIR%"
if errorlevel 1 (
  echo [ERROR] Failed to create venv.
  exit /b 1
)
exit /b 0

:clone_upstream_repo
if exist "%APP_DIR%\pyproject.toml" (
  echo [INFO] Upstream repo already exists: %APP_DIR%
  exit /b 0
)

if exist "%APP_DIR%" (
  echo [ERROR] Target repo directory exists but is incomplete: %APP_DIR%
  echo [ERROR] Please remove it manually, then rerun init.bat.
  exit /b 1
)

echo [INFO] Cloning upstream MOSS-TTS...
git clone --recurse-submodules --branch "%UPSTREAM_REPO_BRANCH%" "%UPSTREAM_REPO_URL%" "%APP_DIR%"
if errorlevel 1 (
  echo [ERROR] Failed to clone upstream repository.
  exit /b 1
)

echo [INFO] Syncing submodules...
git -C "%APP_DIR%" submodule update --init --recursive
if errorlevel 1 (
  echo [ERROR] Failed to initialize submodules.
  exit /b 1
)
exit /b 0

:install_packages
echo [INFO] Upgrading pip/setuptools/wheel...
"%VENV_PYTHON%" -m pip install --upgrade pip setuptools wheel
if errorlevel 1 (
  echo [ERROR] Failed to upgrade packaging tools.
  exit /b 1
)

echo [INFO] Installing PyTorch CUDA 12.8 packages...
"%VENV_PYTHON%" -m pip install --index-url "%TORCH_INDEX_URL%" torch==2.9.1+cu128 torchaudio==2.9.1+cu128
if errorlevel 1 (
  echo [ERROR] Failed to install torch/torchaudio.
  exit /b 1
)

echo [INFO] Installing local MOSS-TTS package with runtime extras...
"%VENV_PYTHON%" -m pip install --extra-index-url "%TORCH_INDEX_URL%" -e "%APP_DIR%[torch-runtime]"
if errorlevel 1 (
  echo [ERROR] Failed to install local MOSS-TTS package.
  exit /b 1
)

echo [INFO] Installing wrapper dependencies...
"%VENV_PYTHON%" -m pip install gradio==6.14.0 modelscope soundfile librosa
if errorlevel 1 (
  echo [ERROR] Failed to install wrapper dependencies.
  exit /b 1
)
exit /b 0

:download_models
set HF_HOME=%HF_HOME%
set TRANSFORMERS_CACHE=%TRANSFORMERS_CACHE%
set MODELSCOPE_CACHE=%MODELSCOPE_CACHE%

if not exist "%MODEL_PATH%" (
  echo [INFO] Downloading %MODEL_TTS_ID%...
  "%VENV_PYTHON%" -c "from modelscope import snapshot_download; snapshot_download('%MODEL_TTS_ID%', local_dir=r'%MODEL_PATH%')"
  if errorlevel 1 (
    echo [ERROR] Failed to download %MODEL_TTS_ID%.
    exit /b 1
  )
)

if not exist "%CODEC_SRC%" (
  echo [INFO] Downloading %MODEL_CODEC_ID%...
  "%VENV_PYTHON%" -c "from modelscope import snapshot_download; snapshot_download('%MODEL_CODEC_ID%', local_dir=r'%CODEC_SRC%')"
  if errorlevel 1 (
    echo [ERROR] Failed to download %MODEL_CODEC_ID%.
    exit /b 1
  )
)
exit /b 0

:create_codec_alias
if exist "%CODEC_LINK%" (
  echo [INFO] Codec alias already exists: %CODEC_LINK%
  exit /b 0
)

if not exist "%CODEC_SRC%" (
  echo [ERROR] Codec source path not found: %CODEC_SRC%
  exit /b 1
)

echo [INFO] Creating codec alias...
cmd /c mklink /J "%CODEC_LINK%" "%CODEC_SRC%"
if errorlevel 1 (
  echo [WARN] Failed to create junction with mklink.
  echo [WARN] Trying PowerShell junction creation...
  powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "if (-not (Test-Path -LiteralPath '%OPENMOSS_DIR%')) { New-Item -ItemType Directory -Force -Path '%OPENMOSS_DIR%' | Out-Null }; if (-not (Test-Path -LiteralPath '%CODEC_LINK%')) { New-Item -ItemType Junction -Path '%CODEC_LINK%' -Target '%CODEC_SRC%' | Out-Null }"
  if errorlevel 1 (
    echo [ERROR] Failed to create codec alias.
    exit /b 1
  )
)
exit /b 0

:export_requirements
echo [INFO] Exporting requirements snapshot...
"%VENV_PYTHON%" -m pip freeze --all > "%REQUIREMENTS_FILE%"
if errorlevel 1 (
  echo [ERROR] Failed to export requirements snapshot.
  exit /b 1
)
exit /b 0

:write_wrapper
echo [INFO] Writing wrapper script: %WRAPPER_PY%
call :write_embedded_file "%WRAPPER_PY%" "@@BEGIN:launch_webui.py@@" "@@END:launch_webui.py@@"
exit /b %ERRORLEVEL%

:write_root_init_wrapper
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$name = -join ([char[]](0x521D,0x59CB,0x5316,0x73AF,0x5883,0x002E,0x0062,0x0061,0x0074)); $target = Join-Path '%ROOT%' $name; $content = @('@echo off','setlocal','call "%%~dp0init.bat"','exit /b %%ERRORLEVEL%%'); Set-Content -LiteralPath $target -Value $content -Encoding ASCII"
if errorlevel 1 (
  echo [ERROR] Failed to write root init wrapper.
  exit /b 1
)
exit /b 0

:write_root_start_cn_wrapper
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$name = -join ([char[]](0x542F,0x52A8,0x0020,0x0057,0x0065,0x0062,0x0055,0x0049,0x002E,0x0062,0x0061,0x0074)); $target = Join-Path '%ROOT%' $name; $content = @('@echo off','setlocal','set "ROOT=%%~dp0"','if "%%ROOT:~-1%%"=="\" set "ROOT=%%ROOT:~0,-1%%"','set "PYTHON_EXE=%%ROOT%%\venv\Scripts\python.exe"','set "APP_SCRIPT=%%ROOT%%\scripts\launch_webui.py"','set "MODEL_PATH=%%ROOT%%\weights\MOSS-TTS-Local-Transformer"','set "HF_HOME=%%ROOT%%\cache\huggingface"','set "TRANSFORMERS_CACHE=%%ROOT%%\cache\huggingface\transformers"','set "MODELSCOPE_CACHE=%%ROOT%%\cache\modelscope"','set "PORT_FILE=%%ROOT%%\logs\webui.port"','set "PORT_MIN=7860"','set "PORT_MAX=7870"','set "SELECTED_PORT="','if not exist "%%PYTHON_EXE%%" (','  echo [ERROR] Python not found: %%PYTHON_EXE%%','  pause','  exit /b 1',')','if not exist "%%APP_SCRIPT%%" (','  echo [ERROR] launch_webui.py not found: %%APP_SCRIPT%%','  pause','  exit /b 1',')','if not exist "%%MODEL_PATH%%" (','  echo [ERROR] Model path not found: %%MODEL_PATH%%','  pause','  exit /b 1',')','if not exist "%%HF_HOME%%" mkdir "%%HF_HOME%%"','if not exist "%%TRANSFORMERS_CACHE%%" mkdir "%%TRANSFORMERS_CACHE%%"','if not exist "%%MODELSCOPE_CACHE%%" mkdir "%%MODELSCOPE_CACHE%%"','if not exist "%%ROOT%%\logs" mkdir "%%ROOT%%\logs"','for /l %%%%P in (%%PORT_MIN%%,1,%%PORT_MAX%%) do (','  netstat -ano ^| findstr /R /C:":%%%%P .*LISTENING" >nul','  if errorlevel 1 (','    set "SELECTED_PORT=%%%%P"','    goto :port_found','  )',')',':port_found','if not defined SELECTED_PORT (','  echo [ERROR] No available port found in range %%PORT_MIN%%-%%PORT_MAX%%.','  pause','  exit /b 1',')','> "%%PORT_FILE%%" echo %%SELECTED_PORT%%','echo [INFO] Starting MOSS-TTS WebUI...','echo [INFO] Root: %%ROOT%%','echo [INFO] Model: %%MODEL_PATH%%','echo [INFO] Port: %%SELECTED_PORT%%','echo [INFO] URL: http://127.0.0.1:%%SELECTED_PORT%%','echo.','"%%PYTHON_EXE%%" "%%APP_SCRIPT%%" --model_path "%%MODEL_PATH%%" --device cuda:0 --port %%SELECTED_PORT%%','set "EXIT_CODE=%%ERRORLEVEL%%"','echo.','echo [INFO] WebUI exited with code %%EXIT_CODE%%.','pause','exit /b %%EXIT_CODE%%'); Set-Content -LiteralPath $target -Value $content -Encoding ASCII"
if errorlevel 1 (
  echo [ERROR] Failed to write Chinese start wrapper.
  exit /b 1
)
exit /b 0

:write_root_stop_cn_wrapper
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$name = -join ([char[]](0x505C,0x6B62,0x0020,0x0057,0x0065,0x0062,0x0055,0x0049,0x002E,0x0062,0x0061,0x0074)); $target = Join-Path '%ROOT%' $name; $content = @('@echo off','setlocal','set "ROOT=%%~dp0"','if "%%ROOT:~-1%%"=="\" set "ROOT=%%ROOT:~0,-1%%"','set "TARGET_PORT="','set "PORT_FILE=%%ROOT%%\logs\webui.port"','set "TARGET_SCRIPT=%%ROOT%%\scripts\launch_webui.py"','set "FOUND_PID="','if exist "%%PORT_FILE%%" (','  set /p TARGET_PORT<"%%PORT_FILE%%"',')','if not defined TARGET_PORT set "TARGET_PORT=7860"','for /f "tokens=5" %%%%P in (''netstat -ano ^| findstr /R /C:":%%TARGET_PORT%% .*LISTENING"'') do (','  set "FOUND_PID=%%%%P"','  goto :have_pid',')',':have_pid','if not defined FOUND_PID (','  echo [INFO] No listening process found on port %%TARGET_PORT%%.','  pause','  exit /b 0',')','for /f "usebackq delims=" %%%%L in (`powershell -NoLogo -NoProfile -Command "(Get-CimInstance Win32_Process -Filter \"ProcessId=%%FOUND_PID%%\").CommandLine"`) do (','  set "CMDLINE=%%%%L"',')','echo [INFO] Found PID %%FOUND_PID%% on port %%TARGET_PORT%%.','echo [INFO] Command: %%CMDLINE%%','echo %%CMDLINE%% ^| find /I "%%TARGET_SCRIPT%%" >nul','if errorlevel 1 (','  echo [WARN] PID %%FOUND_PID%% does not look like the MOSS launch_webui.py process.','  echo [WARN] Refusing to stop it automatically.','  pause','  exit /b 1',')','taskkill /PID %%FOUND_PID%% /T /F','set "EXIT_CODE=%%ERRORLEVEL%%"','echo.','if "%%EXIT_CODE%%"=="0" (','  echo [INFO] MOSS-TTS WebUI stopped.',') else (','  echo [ERROR] Failed to stop PID %%FOUND_PID%%.',')','pause','exit /b %%EXIT_CODE%%'); Set-Content -LiteralPath $target -Value $content -Encoding ASCII"
if errorlevel 1 (
  echo [ERROR] Failed to write Chinese stop wrapper.
  exit /b 1
)
exit /b 0

:write_root_start_bat
> "%ROOT_START_BAT%" (
  echo @echo off
  echo setlocal
  echo call "%%~dp0启动 WebUI.bat"
  echo exit /b %%ERRORLEVEL%%
)
if errorlevel 1 (
  echo [ERROR] Failed to write %ROOT_START_BAT%
  exit /b 1
)
exit /b 0

:write_root_stop_bat
> "%ROOT_STOP_BAT%" (
  echo @echo off
  echo setlocal
  echo call "%%~dp0停止 WebUI.bat"
  echo exit /b %%ERRORLEVEL%%
)
if errorlevel 1 (
  echo [ERROR] Failed to write %ROOT_STOP_BAT%
  exit /b 1
)
exit /b 0

:write_docs_readme
> "%DOCS_DIR%\README.md" (
  echo # docs
  echo.
  echo This directory is created by `init.bat` for local deployment notes and future machine-specific records.
  echo.
  echo The bootstrap branch itself only carries `init.bat`.
)
if errorlevel 1 (
  echo [ERROR] Failed to write docs README.
  exit /b 1
)
exit /b 0

:write_embedded_file
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$self = [IO.Path]::GetFullPath('%SELF_PATH%'); $target = [IO.Path]::GetFullPath('%~1'); $startMarker = '%~2'; $endMarker = '%~3'; $lines = Get-Content -LiteralPath $self -Encoding UTF8; $start = [Array]::IndexOf($lines, $startMarker); $end = [Array]::IndexOf($lines, $endMarker); if ($start -lt 0 -or $end -lt 0 -or $end -le $start) { throw 'Embedded payload marker not found.' }; $content = $lines[($start + 1)..($end - 1)]; $dir = Split-Path -Parent $target; if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }; Set-Content -LiteralPath $target -Value $content -Encoding UTF8"
if errorlevel 1 (
  echo [ERROR] Failed to extract embedded payload into %~1
  exit /b 1
)
exit /b 0

goto :eof
@@BEGIN:launch_webui.py@@
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from xml.sax.saxutils import escape

import librosa
import soundfile as sf
import torch
import torchaudio


ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT / "app" / "MOSS-TTS"
OUTPUT_DIR = ROOT / "outputs"
SRT_OUTPUT_ROOT = OUTPUT_DIR / "srt_jobs"
ROLE_LIBRARY_DIR = ROOT / "data" / "roles"
ROLE_LIBRARY_INDEX = ROLE_LIBRARY_DIR / "roles.json"

if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import clis.moss_tts_app as moss_tts_app  # noqa: E402


@dataclass
class SRTEntry:
    index: int
    start: str
    end: str
    text: str


@dataclass
class RoleEntry:
    name: str
    style: str
    audio_path: str


@dataclass
class TimelineClip:
    subtitle_index: int
    clip_name: str
    file_name: str
    file_path: str
    start_seconds: float
    end_seconds: float
    audio_duration_seconds: float
    track_index: int = 0
    track_group_index: int = 0


MODE_DIRECT = "Direct Generation"
MODE_CLONE = "Clone"

SRT_PARAMETER_PRESETS = {
    "教程配音": {
        "temperature": 1.5,
        "top_p": 0.8,
        "top_k": 25,
        "repetition_penalty": 1.0,
        "max_new_tokens": 512,
    },
    "自然口播版": {
        "temperature": 1.6,
        "top_p": 0.82,
        "top_k": 25,
        "repetition_penalty": 1.0,
        "max_new_tokens": 512,
    },
    "稍有感情但不过火版": {
        "temperature": 1.7,
        "top_p": 0.85,
        "top_k": 30,
        "repetition_penalty": 1.0,
        "max_new_tokens": 512,
    },
}


_orig_slider = moss_tts_app.gr.Slider
_orig_run_inference = moss_tts_app.run_inference
_orig_torchaudio_load = torchaudio.load
_srt_stop_event = threading.Event()
_srt_job_lock = threading.Lock()
_active_srt_job_name: str | None = None


def _safe_slider(*args, **kwargs):
    minimum = kwargs.get("minimum")
    maximum = kwargs.get("maximum")
    if minimum is not None and maximum is not None and minimum >= maximum:
        kwargs["maximum"] = minimum + 1
        value = kwargs.get("value")
        if value is not None and value > kwargs["maximum"]:
            kwargs["value"] = kwargs["maximum"]
    return _orig_slider(*args, **kwargs)


def _safe_run_inference(*args, **kwargs):
    audio_result, status = _orig_run_inference(*args, **kwargs)
    sample_rate, audio_np = audio_result

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        prefix="moss_tts_",
        suffix=".wav",
        dir=str(OUTPUT_DIR),
        delete=False,
    ) as tmp:
        tmp_path = Path(tmp.name)

    sf.write(tmp_path, audio_np, sample_rate)
    return str(tmp_path), status


def _safe_torchaudio_load(path, *args, **kwargs):
    try:
        return _orig_torchaudio_load(path, *args, **kwargs)
    except Exception:
        try:
            audio, sr = sf.read(path, always_2d=True, dtype="float32")
            waveform = torch.from_numpy(audio.T.copy())
            return waveform, int(sr)
        except Exception:
            audio, sr = librosa.load(path, sr=None, mono=False)
            if getattr(audio, "ndim", 1) == 1:
                audio = audio[None, :]
            waveform = torch.as_tensor(audio, dtype=torch.float32)
            return waveform, int(sr)


def _load_role_index() -> list[RoleEntry]:
    ROLE_LIBRARY_DIR.mkdir(parents=True, exist_ok=True)
    if not ROLE_LIBRARY_INDEX.exists():
        return []

    raw = json.loads(ROLE_LIBRARY_INDEX.read_text(encoding="utf-8"))
    roles: list[RoleEntry] = []
    for item in raw:
        roles.append(
            RoleEntry(
                name=str(item.get("name", "")),
                style=str(item.get("style", "")),
                audio_path=str(item.get("audio_path", "")),
            )
        )
    return roles


def _save_role_index(roles: list[RoleEntry]) -> None:
    ROLE_LIBRARY_DIR.mkdir(parents=True, exist_ok=True)
    payload = [
        {"name": role.name, "style": role.style, "audio_path": role.audio_path}
        for role in roles
    ]
    ROLE_LIBRARY_INDEX.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def get_role_table_rows() -> list[list[str]]:
    rows: list[list[str]] = []
    for role in _load_role_index():
        rows.append([role.name, role.style, role.audio_path])
    return rows


def save_custom_role(role_name: str, role_style: str, reference_audio: str | None):
    role_name = (role_name or "").strip()
    role_style = (role_style or "").strip()
    if not role_name:
        return get_role_table_rows(), "Please enter a role name before saving."
    if not reference_audio:
        return get_role_table_rows(), "Please provide a reference audio file before saving."

    safe_name = _sanitize_job_name(role_name)
    role_dir = ROLE_LIBRARY_DIR / safe_name
    role_dir.mkdir(parents=True, exist_ok=True)

    src = Path(reference_audio)
    ext = src.suffix or ".wav"
    stored_audio = role_dir / f"reference{ext}"
    if src.resolve() != stored_audio.resolve():
        data, sr = sf.read(src, always_2d=False)
        sf.write(stored_audio, data, sr)

    roles = [role for role in _load_role_index() if role.name != role_name]
    roles.append(RoleEntry(name=role_name, style=role_style, audio_path=str(stored_audio)))
    roles.sort(key=lambda item: item.name.lower())
    _save_role_index(roles)
    return get_role_table_rows(), f"Saved role: {role_name}"


def delete_custom_role(role_name: str):
    role_name = (role_name or "").strip()
    if not role_name:
        return get_role_table_rows(), "Please enter a role name to delete."

    roles = _load_role_index()
    kept = [role for role in roles if role.name != role_name]
    if len(kept) == len(roles):
        return get_role_table_rows(), f"Role not found: {role_name}"

    _save_role_index(kept)
    return get_role_table_rows(), f"Deleted role: {role_name}"


def apply_custom_role(evt: moss_tts_app.gr.SelectData):
    rows = get_role_table_rows()
    if evt is None or evt.index is None:
        return (
            moss_tts_app.gr.update(),
            moss_tts_app.gr.update(),
            moss_tts_app.gr.update(),
            moss_tts_app.gr.update(),
            "No custom role selected.",
        )

    row_idx = int(evt.index[0] if isinstance(evt.index, (tuple, list)) else evt.index)
    if row_idx < 0 or row_idx >= len(rows):
        return (
            moss_tts_app.gr.update(),
            moss_tts_app.gr.update(),
            moss_tts_app.gr.update(),
            moss_tts_app.gr.update(),
            "Invalid custom role index.",
        )

    name, style, audio_path = rows[row_idx]
    return audio_path, style, name, MODE_CLONE, f"Loaded custom role: {name}"


def _generate_audio_file(
    *,
    text: str,
    reference_audio: str | None,
    instruction: str | None,
    temperature: float,
    top_p: float,
    top_k: int,
    repetition_penalty: float,
    model_path: str,
    device: str,
    attn_implementation: str,
    max_new_tokens: int,
) -> tuple[str, str]:
    started_at = time.monotonic()
    model, processor, torch_device, sample_rate = moss_tts_app.load_backend(
        model_path=model_path,
        device_str=device,
        attn_implementation=attn_implementation,
    )

    user_kwargs: dict[str, object] = {"text": (text or "").strip()}
    if not user_kwargs["text"]:
        raise ValueError("Please enter text to synthesize.")

    if instruction:
        user_kwargs["instruction"] = instruction.strip()

    mode_name = MODE_DIRECT
    if reference_audio:
        user_kwargs["reference"] = [reference_audio]
        mode_name = MODE_CLONE

    conversations = [[processor.build_user_message(**user_kwargs)]]
    batch = processor(conversations, mode="generation")
    input_ids = batch["input_ids"].to(torch_device)
    attention_mask = batch["attention_mask"].to(torch_device)

    with torch.no_grad():
        outputs = model.generate(
            input_ids=input_ids,
            attention_mask=attention_mask,
            max_new_tokens=int(max_new_tokens),
            audio_temperature=float(temperature),
            audio_top_p=float(top_p),
            audio_top_k=int(top_k),
            audio_repetition_penalty=float(repetition_penalty),
        )

    messages = processor.decode(outputs)
    if not messages or messages[0] is None:
        raise RuntimeError("The model did not return a decodable audio result.")

    audio = messages[0].audio_codes_list[0]
    if isinstance(audio, torch.Tensor):
        audio_np = audio.detach().float().cpu().numpy()
    else:
        audio_np = moss_tts_app.np.asarray(audio, dtype=moss_tts_app.np.float32)

    if audio_np.ndim > 1:
        audio_np = audio_np.reshape(-1)
    audio_np = audio_np.astype(moss_tts_app.np.float32, copy=False)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        prefix="moss_tts_",
        suffix=".wav",
        dir=str(OUTPUT_DIR),
        delete=False,
    ) as tmp:
        tmp_path = Path(tmp.name)

    sf.write(tmp_path, audio_np, sample_rate)

    elapsed = time.monotonic() - started_at
    status = (
        f"Done | mode: {mode_name} | elapsed: {elapsed:.2f}s | "
        f"max_new_tokens={int(max_new_tokens)}, "
        f"audio_temperature={float(temperature):.2f}, audio_top_p={float(top_p):.2f}, "
        f"audio_top_k={int(top_k)}, audio_repetition_penalty={float(repetition_penalty):.2f}"
    )
    return str(tmp_path), status


def parse_srt_file(file_path: str | os.PathLike[str]) -> list[SRTEntry]:
    path = Path(file_path)
    raw = path.read_text(encoding="utf-8-sig")
    blocks = re.split(r"\r?\n\s*\r?\n", raw.strip())
    entries: list[SRTEntry] = []

    for block in blocks:
        lines = [line.rstrip() for line in block.splitlines() if line.strip()]
        if len(lines) < 2:
            continue

        try:
            idx = int(lines[0].strip())
            timing = lines[1].strip()
            text_lines = lines[2:]
        except ValueError:
            idx = len(entries) + 1
            timing = lines[0].strip()
            text_lines = lines[1:]

        if "-->" not in timing:
            continue

        start, end = [part.strip() for part in timing.split("-->", 1)]
        text = "\n".join(text_lines).strip()
        entries.append(SRTEntry(index=idx, start=start, end=end, text=text))

    return entries


def preview_srt(srt_file: str | None, skip_empty: bool) -> tuple[list[list[str]], str]:
    if not srt_file:
        return [], "No SRT file selected."

    entries = parse_srt_file(srt_file)
    if skip_empty:
        entries = [entry for entry in entries if entry.text.strip()]

    rows = [[str(entry.index), entry.start, entry.end, entry.text] for entry in entries]
    return rows, f"Parsed {len(rows)} subtitle segments."


def apply_srt_example(evt: moss_tts_app.gr.SelectData):
    if evt is None or evt.index is None:
        return moss_tts_app.gr.update(), moss_tts_app.gr.update(), moss_tts_app.gr.update(), "No example selected."

    row_idx = int(evt.index[0] if isinstance(evt.index, (tuple, list)) else evt.index)
    if row_idx < 0 or row_idx >= len(moss_tts_app.EXAMPLE_ROWS):
        return moss_tts_app.gr.update(), moss_tts_app.gr.update(), moss_tts_app.gr.update(), "Invalid example index."

    role, audio_path, _ = moss_tts_app.EXAMPLE_ROWS[row_idx]
    return str(audio_path), role, MODE_CLONE, f"Loaded example reference audio from role: {role}"


def apply_srt_parameter_preset(preset_name: str):
    preset = SRT_PARAMETER_PRESETS.get(preset_name)
    if preset is None:
        return (
            moss_tts_app.gr.update(),
            moss_tts_app.gr.update(),
            moss_tts_app.gr.update(),
            moss_tts_app.gr.update(),
            moss_tts_app.gr.update(),
            f"Unknown preset: {preset_name}",
        )

    return (
        float(preset["temperature"]),
        float(preset["top_p"]),
        int(preset["top_k"]),
        float(preset["repetition_penalty"]),
        int(preset["max_new_tokens"]),
        f"已应用参数预设：{preset_name}",
    )


def request_stop_srt_generation() -> str:
    global _active_srt_job_name

    _srt_stop_event.set()
    with _srt_job_lock:
        active_job_name = _active_srt_job_name

    if active_job_name:
        return f"已请求停止当前 SRT 任务：{active_job_name}。将在当前片段结束后停止。"
    return "当前没有正在运行的 SRT 任务。"


def _sanitize_job_name(name: str | None) -> str:
    if name is None:
        name = ""
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", name.strip()).strip("_")
    if cleaned:
        return cleaned
    return time.strftime("%Y%m%d_%H%M%S")


def _write_segment_wav(audio_path: str, target_path: Path) -> None:
    target_path.parent.mkdir(parents=True, exist_ok=True)
    data, sr = sf.read(audio_path, always_2d=False)
    sf.write(target_path, data, sr)


def _build_segment_output_name(subtitle_index: int, used_names: set[str]) -> str:
    base_name = f"{int(subtitle_index):04d}"
    candidate = f"{base_name}.wav"
    if candidate not in used_names:
        used_names.add(candidate)
        return candidate

    suffix = 2
    while True:
        candidate = f"{base_name}_dup{suffix}.wav"
        if candidate not in used_names:
            used_names.add(candidate)
            return candidate
        suffix += 1


def _parse_srt_timestamp(timestamp: str) -> float:
    matched = re.fullmatch(r"(\d{2}):(\d{2}):(\d{2}),(\d{3})", (timestamp or "").strip())
    if matched is None:
        raise ValueError(f"Invalid SRT timestamp: {timestamp}")

    hours = int(matched.group(1))
    minutes = int(matched.group(2))
    seconds = int(matched.group(3))
    millis = int(matched.group(4))
    return hours * 3600 + minutes * 60 + seconds + millis / 1000.0


def _seconds_to_frames(seconds: float, fps: int) -> int:
    return max(0, int(round(float(seconds) * fps)))


def _get_audio_duration_seconds(audio_path: str) -> float:
    info = sf.info(audio_path)
    if info.samplerate <= 0:
        raise ValueError(f"Invalid sample rate for audio file: {audio_path}")
    return float(info.frames) / float(info.samplerate)


def _get_audio_file_info(audio_path: str) -> tuple[int, int, int]:
    info = sf.info(audio_path)
    if info.samplerate <= 0:
        raise ValueError(f"Invalid sample rate for audio file: {audio_path}")
    if info.channels <= 0:
        raise ValueError(f"Invalid channel count for audio file: {audio_path}")
    return int(info.frames), int(info.samplerate), int(info.channels)


def _assign_timeline_track_groups(clips: list[TimelineClip]) -> int:
    track_end_times: list[float] = []

    for clip in sorted(clips, key=lambda item: (item.start_seconds, item.subtitle_index, item.file_name)):
        assigned_track = None
        for idx, track_end in enumerate(track_end_times):
            if clip.start_seconds >= track_end:
                assigned_track = idx
                break

        if assigned_track is None:
            track_end_times.append(clip.end_seconds)
            clip.track_group_index = len(track_end_times) - 1
        else:
            track_end_times[assigned_track] = max(track_end_times[assigned_track], clip.end_seconds)
            clip.track_group_index = assigned_track

        clip.track_index = clip.track_group_index + 1

    return len(track_end_times)


def _seconds_to_ppro_ticks(seconds: float) -> int:
    return int(round(float(seconds) * 254016000000.0))


def _build_premiere_xml(job_name: str, clips: list[TimelineClip], xml_path: Path, fps: int = 30) -> Path | None:
    successful_clips = [clip for clip in clips if clip.audio_duration_seconds > 0]
    if not successful_clips:
        return None

    track_group_count = _assign_timeline_track_groups(successful_clips)
    sequence_duration_frames = max(
        _seconds_to_frames(clip.end_seconds, fps)
        for clip in successful_clips
    )

    tracks: list[list[TimelineClip]] = [[] for _ in range(track_group_count)]
    for clip in successful_clips:
        tracks[clip.track_group_index].append(clip)

    audio_track_blocks: list[str] = []
    clip_item_counter = 1
    file_counter = 1
    sequence_sample_rate = 48000
    for clip in successful_clips:
        _, clip_sample_rate, _ = _get_audio_file_info(clip.file_path)
        sequence_sample_rate = clip_sample_rate
        break

    for track_group_number, track_clips in enumerate(tracks, start=0):
        clip_blocks: list[str] = []
        for clip in sorted(track_clips, key=lambda item: (item.start_seconds, item.subtitle_index, item.file_name)):
            start_frame = _seconds_to_frames(clip.start_seconds, fps)
            duration_frames = max(1, _seconds_to_frames(clip.audio_duration_seconds, fps))
            end_frame = start_frame + duration_frames
            pathurl = Path(clip.file_path).resolve().as_uri()
            _, file_sample_rate, file_channels = _get_audio_file_info(clip.file_path)
            clip_id = clip_item_counter
            clip_item_counter += 1
            file_id = f"file-{file_counter}"
            file_counter += 1
            ppro_ticks_in = 0
            ppro_ticks_out = _seconds_to_ppro_ticks(clip.audio_duration_seconds)

            full_file_block = """
                        <file id=\"{file_id}\">
                            <name>{name}</name>
                            <pathurl>{pathurl}</pathurl>
                            <rate>
                                <timebase>{fps}</timebase>
                                <ntsc>FALSE</ntsc>
                            </rate>
                            <duration>{duration_frames}</duration>
                            <timecode>
                                <rate>
                                    <timebase>{fps}</timebase>
                                    <ntsc>FALSE</ntsc>
                                </rate>
                                <string>00:00:00:00</string>
                                <frame>0</frame>
                                <displayformat>NDF</displayformat>
                            </timecode>
                            <media>
                                <audio>
                                    <samplecharacteristics>
                                        <depth>16</depth>
                                        <samplerate>{samplerate}</samplerate>
                                    </samplecharacteristics>
                                    <channelcount>{channelcount}</channelcount>
                                </audio>
                            </media>
                        </file>""".format(
                file_id=file_id,
                name=escape(clip.file_name),
                pathurl=escape(pathurl),
                fps=fps,
                duration_frames=duration_frames,
                samplerate=file_sample_rate,
                channelcount=file_channels,
            )

            clip_blocks.append(
                """
                    <clipitem id=\"clipitem-{clip_id}\">
                        <name>{name}</name>
                        <enabled>TRUE</enabled>
                        <duration>{duration}</duration>
                        <rate>
                            <timebase>{fps}</timebase>
                            <ntsc>FALSE</ntsc>
                        </rate>
                        <start>{start}</start>
                        <end>{end}</end>
                        <in>0</in>
                        <out>{out}</out>
                        <pproTicksIn>{ppro_ticks_in}</pproTicksIn>
                        <pproTicksOut>{ppro_ticks_out}</pproTicksOut>
{file_block}
                        <sourcetrack>
                            <mediatype>audio</mediatype>
                            <trackindex>1</trackindex>
                        </sourcetrack>
                        <logginginfo>
                            <description></description>
                            <scene></scene>
                            <shottake></shottake>
                            <lognote></lognote>
                            <good></good>
                            <originalvideofilename></originalvideofilename>
                            <originalaudiofilename></originalaudiofilename>
                        </logginginfo>
                        <colorinfo>
                            <lut></lut>
                            <lut1></lut1>
                            <asc_sop></asc_sop>
                            <asc_sat></asc_sat>
                            <lut2></lut2>
                        </colorinfo>
                    </clipitem>""".format(
                clip_id=clip_id,
                name=escape(clip.file_name),
                start=start_frame,
                end=end_frame,
                out=duration_frames,
                duration=duration_frames,
                ppro_ticks_in=ppro_ticks_in,
                ppro_ticks_out=ppro_ticks_out,
                file_block=full_file_block,
                fps=fps,
            )
            )

        audio_track_blocks.append(
            """
                <track>
{clips}
                    <enabled>TRUE</enabled>
                    <locked>FALSE</locked>
                    <outputchannelindex>1</outputchannelindex>
                </track>""".format(clips="\n".join(clip_blocks))
        )

    xml_text = """<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE xmeml>
<xmeml version=\"4\">
    <sequence id=\"sequence-1\">
        <uuid>{sequence_uuid}</uuid>
        <duration>{duration}</duration>
        <rate>
            <timebase>{fps}</timebase>
            <ntsc>FALSE</ntsc>
        </rate>
        <name>{sequence_name}</name>
        <media>
            <video>
                <track>
                    <enabled>TRUE</enabled>
                    <locked>FALSE</locked>
                </track>
            </video>
            <audio>
                <format>
                    <samplecharacteristics>
                        <depth>16</depth>
                        <samplerate>{sequence_sample_rate}</samplerate>
                    </samplecharacteristics>
                </format>
{audio_tracks}
            </audio>
        </media>
        <timecode>
            <rate>
                <timebase>{fps}</timebase>
                <ntsc>FALSE</ntsc>
            </rate>
            <string>00:00:00:00</string>
            <frame>0</frame>
            <displayformat>NDF</displayformat>
        </timecode>
        <logginginfo>
            <description></description>
            <scene></scene>
            <shottake></shottake>
            <lognote></lognote>
            <good></good>
            <originalvideofilename></originalvideofilename>
            <originalaudiofilename></originalaudiofilename>
        </logginginfo>
    </sequence>
</xmeml>
""".format(
        sequence_uuid=f"premiere-{job_name}",
        sequence_name=escape(job_name),
        duration=max(1, sequence_duration_frames),
        fps=fps,
        sequence_sample_rate=sequence_sample_rate,
        audio_tracks="\n".join(audio_track_blocks),
    )

    xml_path.write_text(xml_text, encoding="utf-8")
    return xml_path


def generate_srt_segments(
    srt_file: str | None,
    reference_audio: str | None,
    mode_with_reference: str,
    custom_role: str,
    job_name: str,
    skip_empty: bool,
    temperature: float,
    top_p: float,
    top_k: int,
    repetition_penalty: float,
    max_new_tokens: int,
    model_path: str,
    device: str,
    attn_implementation: str,
):
    global _active_srt_job_name

    if not srt_file:
        raise ValueError("Please select an SRT file.")

    entries = parse_srt_file(srt_file)
    if skip_empty:
        entries = [entry for entry in entries if entry.text.strip()]

    if not entries:
        raise ValueError("No usable subtitle entries were found in the SRT file.")

    resolved_mode = mode_with_reference if reference_audio else MODE_DIRECT
    job_dir = SRT_OUTPUT_ROOT / _sanitize_job_name(job_name)
    job_dir.mkdir(parents=True, exist_ok=True)

    _srt_stop_event.clear()
    with _srt_job_lock:
        _active_srt_job_name = job_dir.name

    manifest: list[dict[str, str | int | bool]] = []
    rows: list[list[str]] = []
    used_output_names: set[str] = set()
    timeline_clips: list[TimelineClip] = []

    yield rows, f"Started SRT job in {job_dir} | total={len(entries)}", str(job_dir)

    stopped = False
    try:
        for processed_count, entry in enumerate(entries, start=1):
            if _srt_stop_event.is_set():
                stopped = True
                break

            try:
                actual_reference_audio = reference_audio if resolved_mode == MODE_CLONE else None
                audio_path, status = _generate_audio_file(
                    text=entry.text,
                    reference_audio=actual_reference_audio,
                    instruction=custom_role,
                    temperature=temperature,
                    top_p=top_p,
                    top_k=top_k,
                    repetition_penalty=repetition_penalty,
                    model_path=model_path,
                    device=device,
                    attn_implementation=attn_implementation,
                    max_new_tokens=max_new_tokens,
                )
                out_name = _build_segment_output_name(entry.index, used_output_names)
                out_path = job_dir / out_name
                _write_segment_wav(audio_path, out_path)
                clip_start_seconds = _parse_srt_timestamp(entry.start)
                clip_end_seconds = _parse_srt_timestamp(entry.end)
                audio_duration_seconds = _get_audio_duration_seconds(str(out_path))
                generated_end_seconds = clip_start_seconds + audio_duration_seconds
                timeline_clips.append(
                    TimelineClip(
                        subtitle_index=entry.index,
                        clip_name=out_name,
                        file_name=out_name,
                        file_path=str(out_path),
                        start_seconds=clip_start_seconds,
                        end_seconds=generated_end_seconds,
                        audio_duration_seconds=audio_duration_seconds,
                    )
                )
                row = [str(entry.index), entry.start, entry.end, entry.text, out_name, "ok"]
                manifest.append(
                    {
                        "subtitle_index": entry.index,
                        "start": entry.start,
                        "end": entry.end,
                        "text": entry.text,
                        "custom_role": custom_role,
                        "output_file": out_name,
                        "timeline_start_seconds": clip_start_seconds,
                        "subtitle_end_seconds": clip_end_seconds,
                        "timeline_end_seconds": generated_end_seconds,
                        "audio_duration_seconds": audio_duration_seconds,
                        "overlaps_subtitle_end": generated_end_seconds > clip_end_seconds,
                        "status": "ok",
                        "message": status,
                    }
                )
            except Exception as exc:  # noqa: BLE001
                row = [str(entry.index), entry.start, entry.end, entry.text, "", f"error: {exc}"]
                manifest.append(
                    {
                        "subtitle_index": entry.index,
                        "start": entry.start,
                        "end": entry.end,
                        "text": entry.text,
                        "custom_role": custom_role,
                        "output_file": "",
                        "status": "error",
                        "message": str(exc),
                    }
                )
            rows.append(row)

            progress_state = "Stopping requested" if _srt_stop_event.is_set() else "Running"
            yield (
                rows,
                f"{progress_state} SRT job in {job_dir} | processed={processed_count}/{len(entries)} | last={entry.index}",
                str(job_dir),
            )

            if _srt_stop_event.is_set():
                stopped = True
                break

        timeline_xml_path = _build_premiere_xml(
            job_name=job_dir.name,
            clips=timeline_clips,
            xml_path=job_dir / "premiere_timeline.xml",
        )

        track_by_output_file = {clip.file_name: clip.track_group_index + 1 for clip in timeline_clips}
        for item in manifest:
            output_file = str(item.get("output_file", ""))
            if output_file in track_by_output_file:
                item["timeline_track"] = track_by_output_file[output_file]

        manifest_path = job_dir / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")

        success_count = sum(1 for item in manifest if item["status"] == "ok")
        if stopped:
            status_text = (
                f"Stopped SRT job in {job_dir} | success={success_count}/{len(manifest)} | "
                f"manifest={manifest_path.name}"
            )
        else:
            status_text = (
                f"Finished SRT job in {job_dir} | success={success_count}/{len(manifest)} | "
                f"manifest={manifest_path.name}"
            )
        if timeline_xml_path is not None:
            status_text += f" | timeline={timeline_xml_path.name}"
        yield rows, status_text, str(job_dir)
    finally:
        _srt_stop_event.clear()
        with _srt_job_lock:
            _active_srt_job_name = None


def build_wrapped_demo(args: argparse.Namespace):
    gr = moss_tts_app.gr
    base_demo = moss_tts_app.build_demo(args)

    def run_srt_job(
        srt_file,
        reference_audio,
        mode_with_reference,
        custom_role,
        job_name,
        skip_empty,
        temperature,
        top_p,
        top_k,
        repetition_penalty,
        max_new_tokens,
    ):
        yield from generate_srt_segments(
            srt_file=srt_file,
            reference_audio=reference_audio,
            mode_with_reference=mode_with_reference,
            custom_role=custom_role,
            job_name=job_name,
            skip_empty=skip_empty,
            temperature=temperature,
            top_p=top_p,
            top_k=top_k,
            repetition_penalty=repetition_penalty,
            max_new_tokens=max_new_tokens,
            model_path=args.model_path,
            device=args.device,
            attn_implementation=args.attn_implementation,
        )

    with gr.Blocks(title="MOSS-TTS Portable") as demo:
        with gr.Tabs():
            with gr.Tab("基础 TTS"):
                base_demo.render()

            with gr.Tab("SRT 分段转音频"):
                gr.Markdown(
                    """
                    <div class="app-card">
                      <div class="app-title">SRT 分段转音频</div>
                      <div class="app-subtitle">上传 SRT 后按字幕逐段生成独立 wav 文件，不合成整轨。</div>
                    </div>
                    """
                )

                with gr.Row(equal_height=False):
                    with gr.Column(scale=3):
                        srt_file = gr.File(label="SRT 文件", file_types=[".srt"], type="filepath")
                        srt_reference_audio = gr.Audio(label="参考音频（可选）", type="filepath")
                        srt_mode = gr.Radio(
                            choices=[MODE_DIRECT, MODE_CLONE],
                            value=MODE_DIRECT,
                            label="模式",
                            info="不上传参考音频时会自动按直生处理。",
                        )
                        srt_custom_role = gr.Textbox(
                            label="自定义角色/风格设定（可选）",
                            lines=3,
                            placeholder="例如：温柔女声，沉稳播音腔，轻松自然的讲述风格",
                        )
                        srt_role_name = gr.Textbox(
                            label="角色名称（用于保存角色库）",
                            placeholder="例如：旁白女声A",
                        )
                        srt_job_name = gr.Textbox(label="输出任务名（可选）", placeholder="留空则使用时间戳")
                        srt_skip_empty = gr.Checkbox(value=True, label="跳过空字幕")

                        with gr.Accordion("SRT 生成参数", open=True):
                            gr.Markdown("点击下方预设可快速回填参数，不会修改风格提示词、参考音频或模式。")
                            with gr.Row():
                                srt_preset_tutorial_btn = gr.Button("教程配音", variant="secondary")
                                srt_preset_natural_btn = gr.Button("自然口播版", variant="secondary")
                                srt_preset_expressive_btn = gr.Button("稍有感情但不过火版", variant="secondary")
                            srt_temperature = gr.Slider(minimum=0.1, maximum=3.0, step=0.05, value=1.7, label="temperature")
                            srt_top_p = gr.Slider(minimum=0.1, maximum=1.0, step=0.01, value=0.8, label="top_p")
                            srt_top_k = gr.Slider(minimum=1, maximum=200, step=1, value=25, label="top_k")
                            srt_repetition_penalty = gr.Slider(minimum=0.8, maximum=2.0, step=0.05, value=1.0, label="repetition_penalty")
                            srt_max_new_tokens = gr.Slider(minimum=256, maximum=8192, step=128, value=512, label="max_new_tokens")

                        preview_btn = gr.Button("预览字幕", variant="secondary")
                        save_role_btn = gr.Button("保存为自定义角色", variant="secondary")
                        delete_role_btn = gr.Button("删除当前角色名", variant="secondary")
                        with gr.Row():
                            srt_run_btn = gr.Button("开始生成分段音频", variant="primary")
                            srt_stop_btn = gr.Button("停止当前生成", variant="stop")

                    with gr.Column(scale=4):
                        srt_preview_status = gr.Textbox(label="解析状态", interactive=False)
                        srt_preview_table = gr.Dataframe(
                            headers=["序号", "开始", "结束", "文本"],
                            datatype=["str", "str", "str", "str"],
                            row_count=(1, "dynamic"),
                            col_count=(4, "fixed"),
                            interactive=False,
                            wrap=True,
                            label="字幕预览",
                        )
                        srt_result_status = gr.Textbox(label="生成状态", interactive=False, lines=4)
                        srt_result_dir = gr.Textbox(label="输出目录", interactive=False)
                        srt_result_table = gr.Dataframe(
                            headers=["序号", "开始", "结束", "文本", "输出文件", "状态"],
                            datatype=["str", "str", "str", "str", "str", "str"],
                            row_count=(1, "dynamic"),
                            col_count=(6, "fixed"),
                            interactive=False,
                            wrap=True,
                            label="生成结果",
                        )
                        srt_examples_table = gr.Dataframe(
                            headers=["Role", "Reference Speech", "Example Text"],
                            value=[[role, str(audio_path), text] for role, audio_path, text in moss_tts_app.EXAMPLE_ROWS],
                            datatype=["str", "str", "str"],
                            row_count=(len(moss_tts_app.EXAMPLE_ROWS), "fixed"),
                            col_count=(3, "fixed"),
                            interactive=False,
                            wrap=True,
                            label="Examples (click a row to fill inputs)",
                        )
                        srt_custom_roles_table = gr.Dataframe(
                            headers=["Role Name", "Style", "Reference Audio"],
                            value=get_role_table_rows(),
                            datatype=["str", "str", "str"],
                            row_count=(1, "dynamic"),
                            col_count=(3, "fixed"),
                            interactive=False,
                            wrap=True,
                            label="自定义角色库（click a row to fill inputs）",
                        )

                preview_btn.click(
                    fn=preview_srt,
                    inputs=[srt_file, srt_skip_empty],
                    outputs=[srt_preview_table, srt_preview_status],
                )

                srt_examples_table.select(
                    fn=apply_srt_example,
                    inputs=None,
                    outputs=[srt_reference_audio, srt_custom_role, srt_mode, srt_preview_status],
                )

                srt_custom_roles_table.select(
                    fn=apply_custom_role,
                    inputs=None,
                    outputs=[srt_reference_audio, srt_custom_role, srt_role_name, srt_mode, srt_preview_status],
                )

                save_role_btn.click(
                    fn=save_custom_role,
                    inputs=[srt_role_name, srt_custom_role, srt_reference_audio],
                    outputs=[srt_custom_roles_table, srt_preview_status],
                )

                delete_role_btn.click(
                    fn=delete_custom_role,
                    inputs=[srt_role_name],
                    outputs=[srt_custom_roles_table, srt_preview_status],
                )

                srt_preset_tutorial_btn.click(
                    fn=lambda: apply_srt_parameter_preset("教程配音"),
                    inputs=None,
                    outputs=[
                        srt_temperature,
                        srt_top_p,
                        srt_top_k,
                        srt_repetition_penalty,
                        srt_max_new_tokens,
                        srt_preview_status,
                    ],
                )

                srt_preset_natural_btn.click(
                    fn=lambda: apply_srt_parameter_preset("自然口播版"),
                    inputs=None,
                    outputs=[
                        srt_temperature,
                        srt_top_p,
                        srt_top_k,
                        srt_repetition_penalty,
                        srt_max_new_tokens,
                        srt_preview_status,
                    ],
                )

                srt_preset_expressive_btn.click(
                    fn=lambda: apply_srt_parameter_preset("稍有感情但不过火版"),
                    inputs=None,
                    outputs=[
                        srt_temperature,
                        srt_top_p,
                        srt_top_k,
                        srt_repetition_penalty,
                        srt_max_new_tokens,
                        srt_preview_status,
                    ],
                )

                srt_stop_btn.click(
                    fn=request_stop_srt_generation,
                    inputs=None,
                    outputs=[srt_result_status],
                    queue=False,
                )

                srt_run_btn.click(
                    fn=run_srt_job,
                    inputs=[
                        srt_file,
                        srt_reference_audio,
                        srt_mode,
                        srt_custom_role,
                        srt_job_name,
                        srt_skip_empty,
                        srt_temperature,
                        srt_top_p,
                        srt_top_k,
                        srt_repetition_penalty,
                        srt_max_new_tokens,
                    ],
                    outputs=[srt_result_table, srt_result_status, srt_result_dir],
                )

    return demo


def main():
    parser = argparse.ArgumentParser(description="Wrapped MossTTS Gradio Demo")
    parser.add_argument("--model_path", type=str, default=moss_tts_app.MODEL_PATH)
    parser.add_argument("--device", type=str, default="cuda:0")
    parser.add_argument("--attn_implementation", type=str, default=moss_tts_app.DEFAULT_ATTN_IMPLEMENTATION)
    parser.add_argument("--host", type=str, default="0.0.0.0")
    parser.add_argument("--port", type=int, default=7860)
    parser.add_argument("--share", action="store_true")
    args = parser.parse_args()

    runtime_device = torch.device(args.device if torch.cuda.is_available() else "cpu")
    runtime_dtype = torch.bfloat16 if runtime_device.type == "cuda" else torch.float32
    args.attn_implementation = moss_tts_app.resolve_attn_implementation(
        requested=args.attn_implementation,
        device=runtime_device,
        dtype=runtime_dtype,
    ) or "none"
    print(f"[INFO] Using attn_implementation={args.attn_implementation}", flush=True)

    preload_started_at = time.monotonic()
    print(
        f"[Startup] Preloading backend: model={args.model_path}, device={args.device}, attn={args.attn_implementation}",
        flush=True,
    )
    moss_tts_app.load_backend(
        model_path=args.model_path,
        device_str=args.device,
        attn_implementation=args.attn_implementation,
    )
    print(
        f"[Startup] Backend preload finished in {time.monotonic() - preload_started_at:.2f}s",
        flush=True,
    )

    demo = build_wrapped_demo(args)
    demo.queue(max_size=16, default_concurrency_limit=1).launch(
        server_name=args.host,
        server_port=args.port,
        share=args.share,
        show_error=True,
    )


moss_tts_app.gr.Slider = _safe_slider
moss_tts_app.run_inference = _safe_run_inference
torchaudio.load = _safe_torchaudio_load


if __name__ == "__main__":
    main()
@@END:launch_webui.py@@
