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
    "稳定连续版": {
        "temperature": 1.35,
        "top_p": 0.78,
        "top_k": 20,
        "repetition_penalty": 1.02,
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


def _merge_consistency_instruction(custom_role: str | None) -> str:
    consistency = (
        "请尽量保持所有字幕分段的音色、语速、音量和语气一致。"
        "使用稳定、自然、连贯的讲述方式，不要在不同分段之间突然改变情绪或说话风格。"
    )
    custom_role = (custom_role or "").strip()
    if custom_role:
        return f"{custom_role}\n{consistency}"
    return consistency


def _set_generation_seed(seed: int | None) -> None:
    if seed is None or int(seed) < 0:
        return
    resolved_seed = int(seed)
    torch.manual_seed(resolved_seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(resolved_seed)


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
    seed: int | None = None,
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
        _set_generation_seed(seed)
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
        f"audio_top_k={int(top_k)}, audio_repetition_penalty={float(repetition_penalty):.2f}, "
        f"seed={seed if seed is not None else -1}"
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


def _write_job_manifest(job_dir: Path, manifest: list[dict[str, object]]) -> Path:
    manifest_path = job_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    return manifest_path


def _write_job_progress(
    job_dir: Path,
    *,
    job_name: str,
    total: int,
    processed: int,
    success: int,
    failed: int,
    last_subtitle_index: int | None,
    status: str,
    stopped: bool,
) -> Path:
    progress_path = job_dir / "progress.json"
    payload = {
        "job_name": job_name,
        "status": status,
        "total": int(total),
        "processed": int(processed),
        "success": int(success),
        "failed": int(failed),
        "last_subtitle_index": None if last_subtitle_index is None else int(last_subtitle_index),
        "stopped": bool(stopped),
        "updated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    progress_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return progress_path


def load_existing_srt_job(job_name_or_path: str):
    raw = (job_name_or_path or "").strip()
    if not raw:
        return [], "请输入任务名或任务目录。", ""

    candidate = Path(raw)
    job_dir = candidate if candidate.is_absolute() else (SRT_OUTPUT_ROOT / raw)
    if not job_dir.exists() or not job_dir.is_dir():
        return [], f"任务目录不存在：{job_dir}", str(job_dir)

    manifest_path = job_dir / "manifest.json"
    progress_path = job_dir / "progress.json"
    if not manifest_path.exists():
        return [], f"未找到 manifest.json：{job_dir}", str(job_dir)

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    rows: list[list[str]] = []
    for item in manifest:
        rows.append([
            str(item.get("subtitle_index", "")),
            str(item.get("start", "")),
            str(item.get("end", "")),
            str(item.get("text", "")),
            str(item.get("output_file", "")),
            str(item.get("status", "")),
        ])

    if progress_path.exists():
        progress = json.loads(progress_path.read_text(encoding="utf-8"))
        status_text = (
            f"已加载任务：{job_dir.name} | status={progress.get('status', 'unknown')} | "
            f"processed={progress.get('processed', 0)}/{progress.get('total', 0)} | "
            f"success={progress.get('success', 0)} | failed={progress.get('failed', 0)}"
        )
    else:
        success_count = sum(1 for item in manifest if str(item.get("status", "")) == "ok")
        error_count = sum(1 for item in manifest if str(item.get("status", "")) == "error")
        status_text = (
            f"已加载任务：{job_dir.name} | processed={len(manifest)} | "
            f"success={success_count} | failed={error_count}"
        )

    return rows, status_text, str(job_dir)


def _load_existing_manifest_for_resume(job_dir: Path) -> tuple[list[dict[str, object]], dict[int, dict[str, object]]]:
    manifest_path = job_dir / "manifest.json"
    if not manifest_path.exists():
        return [], {}

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    completed: dict[int, dict[str, object]] = {}
    for item in manifest:
        try:
            subtitle_index = int(item.get("subtitle_index"))
        except Exception:
            continue
        output_file = str(item.get("output_file", "") or "")
        status = str(item.get("status", "") or "")
        if status != "ok" or not output_file:
            continue
        out_path = job_dir / output_file
        if out_path.exists() and out_path.is_file():
            completed[subtitle_index] = item
    return manifest, completed


def generate_srt_segments(
    srt_file: str | None,
    reference_audio: str | None,
    mode_with_reference: str,
    custom_role: str,
    job_name: str,
    skip_empty: bool,
    resume_existing_job: bool,
    keep_consistency: bool,
    seed: float,
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
    completed_entries: dict[int, dict[str, object]] = {}
    resumed_count = 0

    if resume_existing_job:
        existing_manifest, completed_entries = _load_existing_manifest_for_resume(job_dir)
        manifest = [dict(item) for item in existing_manifest]
        seen_files = {
            str(item.get("output_file", "") or "")
            for item in manifest
            if str(item.get("output_file", "") or "")
        }
        used_output_names = set(seen_files)
        for subtitle_index, item in sorted(completed_entries.items()):
            output_file = str(item.get("output_file", "") or "")
            out_path = job_dir / output_file
            try:
                audio_duration_seconds = _get_audio_duration_seconds(str(out_path))
                clip_start_seconds = float(item.get("timeline_start_seconds", _parse_srt_timestamp(str(item.get("start", "")))))
                generated_end_seconds = float(item.get("timeline_end_seconds", clip_start_seconds + audio_duration_seconds))
                timeline_clips.append(
                    TimelineClip(
                        subtitle_index=subtitle_index,
                        clip_name=output_file,
                        file_name=output_file,
                        file_path=str(out_path),
                        start_seconds=clip_start_seconds,
                        end_seconds=generated_end_seconds,
                        audio_duration_seconds=audio_duration_seconds,
                    )
                )
            except Exception:
                pass
        resumed_count = len(completed_entries)
        for entry in entries:
            if entry.index in completed_entries:
                item = completed_entries[entry.index]
                rows.append([
                    str(entry.index),
                    entry.start,
                    entry.end,
                    entry.text,
                    str(item.get("output_file", "")),
                    "ok(existing)",
                ])

    _write_job_manifest(job_dir, manifest)
    _write_job_progress(
        job_dir,
        job_name=job_dir.name,
        total=len(entries),
        processed=len(manifest),
        success=sum(1 for item in manifest if item["status"] == "ok"),
        failed=sum(1 for item in manifest if item["status"] == "error"),
        last_subtitle_index=(None if not manifest else int(manifest[-1]["subtitle_index"])),
        status="running",
        stopped=False,
    )

    start_message = f"Started SRT job in {job_dir} | total={len(entries)}"
    if resume_existing_job:
        start_message += f" | resumed={resumed_count}"
    yield rows, start_message, str(job_dir)

    stopped = False
    try:
        for processed_count, entry in enumerate(entries, start=1):
            if entry.index in completed_entries:
                continue
            if _srt_stop_event.is_set():
                stopped = True
                break

            try:
                actual_reference_audio = reference_audio if resolved_mode == MODE_CLONE else None
                actual_instruction = _merge_consistency_instruction(custom_role) if keep_consistency else custom_role
                base_seed = int(seed)
                actual_seed = None if base_seed < 0 else base_seed + int(entry.index)
                audio_path, status = _generate_audio_file(
                    text=entry.text,
                    reference_audio=actual_reference_audio,
                    instruction=actual_instruction,
                    temperature=temperature,
                    top_p=top_p,
                    top_k=top_k,
                    repetition_penalty=repetition_penalty,
                    model_path=model_path,
                    device=device,
                    attn_implementation=attn_implementation,
                    max_new_tokens=max_new_tokens,
                    seed=actual_seed,
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
                        "keep_consistency": bool(keep_consistency),
                        "seed": -1 if actual_seed is None else int(actual_seed),
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
                        "keep_consistency": bool(keep_consistency),
                        "seed": -1,
                        "output_file": "",
                        "status": "error",
                        "message": str(exc),
                    }
                )
            rows.append(row)

            success_count = sum(1 for item in manifest if item["status"] == "ok")
            failed_count = sum(1 for item in manifest if item["status"] == "error")
            _write_job_manifest(job_dir, manifest)
            _write_job_progress(
                job_dir,
                job_name=job_dir.name,
                total=len(entries),
                processed=len(manifest),
                success=success_count,
                failed=failed_count,
                last_subtitle_index=entry.index,
                status="running",
                stopped=bool(_srt_stop_event.is_set()),
            )

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

        manifest_path = _write_job_manifest(job_dir, manifest)

        success_count = sum(1 for item in manifest if item["status"] == "ok")
        failed_count = sum(1 for item in manifest if item["status"] == "error")
        final_status = "stopped" if stopped else "finished"
        _write_job_progress(
            job_dir,
            job_name=job_dir.name,
            total=len(entries),
            processed=len(manifest),
            success=success_count,
            failed=failed_count,
            last_subtitle_index=(None if not manifest else int(manifest[-1]["subtitle_index"])),
            status=final_status,
            stopped=stopped,
        )

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
        resume_existing_job,
        keep_consistency,
        seed,
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
            resume_existing_job=resume_existing_job,
            keep_consistency=keep_consistency,
            seed=seed,
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
                        srt_resume_existing_job = gr.Checkbox(value=True, label="继续已有任务（跳过已完成片段）")
                        srt_keep_consistency = gr.Checkbox(value=True, label="保持分段一致性")
                        srt_seed = gr.Number(value=-1, precision=0, label="随机种子（-1 表示随机）")

                        with gr.Accordion("SRT 生成参数", open=True):
                            gr.Markdown("点击下方预设可快速回填参数，不会修改风格提示词、参考音频或模式。")
                            with gr.Row():
                                srt_preset_tutorial_btn = gr.Button("教程配音", variant="secondary")
                                srt_preset_natural_btn = gr.Button("自然口播版", variant="secondary")
                                srt_preset_stable_btn = gr.Button("稳定连续版", variant="secondary")
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
                        srt_load_job_name = gr.Textbox(label="加载已有任务（任务名或目录，可选）", placeholder="例如：20260523_123000 或完整目录路径")
                        srt_load_job_btn = gr.Button("加载已有任务", variant="secondary")
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

                srt_preset_stable_btn.click(
                    fn=lambda: apply_srt_parameter_preset("稳定连续版"),
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

                srt_load_job_btn.click(
                    fn=load_existing_srt_job,
                    inputs=[srt_load_job_name],
                    outputs=[srt_result_table, srt_result_status, srt_result_dir],
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
                        srt_resume_existing_job,
                        srt_keep_consistency,
                        srt_seed,
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
