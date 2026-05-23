# MOSS-TTS (SRT/TTS Enhanced Branch)

This repository is based on `MOSS-TTS` and adds local workflow enhancements for subtitle-based dubbing and batch audio generation.

## Branch Purpose

This branch is intended to:

- provide a more practical local WebUI startup flow
- support an `SRT to segmented audio` workflow
- add local enhancements such as role library, parameter presets, and stop-current-generation
- keep upstream compatibility while maintaining local enhancements in a wrapper layer

## Added Features

- SRT to segmented audio
- local role library
- parameter presets
- stop current generation
- load existing task results
- resume the same job by skipping completed segments
- Premiere XML export
- WebUI port fallback improvements
- some Gradio compatibility fixes

## Quick Start

1. Run `init.bat`
2. Wait for environment setup to finish
3. Run `启动 WebUI.bat`

## Key Entry Points

- `init.bat`: environment setup
- `scripts/launch_webui.py`: local enhancement entry
- `启动 WebUI.bat`: start WebUI

## Notes

- This is not a plain upstream mirror; it is an enhanced working branch
- Model weights, caches, outputs, and local data should not be committed
- For the Chinese version, see `README.md`
