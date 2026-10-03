# AGENTS.md

Guidance for any coding agent working in this repository.

## Project context

This repository contains an MPV Lua script for cutting and extracting video segments with FFmpeg and yt-dlp, supporting instant cuts, quick cuts of preceding playback, queue and merge workflows, on-screen settings menu, visual timeline overlay, and configurable keybindings.

Primary files:

- `scripts/video-segment-cutter.lua` — main script logic (single-file architecture)
- `script-opts/video_cutter.conf` — user-overridable flat options and keybindings
- `README.md` — user-facing documentation and usage guide
- `test/run.sh` — automated end-to-end smoke test suite (T1-T4)
- `test/driver.lua` — headless MPV test harness driver
- `test/range_server.py` — range-request HTTP server fixture for yt-dlp tests

---

## Mission

When changing code here, optimize for:

1. **Reliability during playback** (no crashes, no blocking loops, no orphaned subprocesses)
2. **Clear user controls** (predictable keybindings, clean OSD/HUD messages)
3. **Single-file integrity** (all script runtime logic stays in `scripts/video-segment-cutter.lua`)
4. **Documentation parity** (README, AGENTS.md, and `video_cutter.conf` updated in lockstep)
5. **Regression safety** (automated test suite in `test/run.sh` must remain green)

---

## Hard constraints

- **Single-file script**: Do not split `scripts/video-segment-cutter.lua` into multi-file modules. Users install by copying a single `.lua` file into their MPV scripts folder.
- **No speculative features**: Implement only what was requested or strictly required to solve the target issue.
- **No unprompted refactoring**: Do not reformat or reorganize unrelated sections.
- **MPV Lua compatibility**: Maintain compatibility with Lua 5.1 / LuaJIT runtime environments used in MPV across Linux, macOS, and Windows.
- **Flat configuration schema**: `mp.options.read_options` only maps flat top-level keys. Nested runtime options must be handled via explicit setters, the Settings Menu, or `.video_cutter_settings.json`.
- **Keybinding safety**: An empty key value in `video_cutter.conf` (e.g. `key_toggle_mark=`) must cleanly unbind that key without registering empty bindings.
- **Subprocess discipline**: Always use asynchronous subprocess APIs (`mp.command_native_async` or detached commands). Never block MPV's event loop. Always clean up temporary files and cancel pending child processes on quit or error.

---

## Architecture and Subsystems

### 1) Configuration and state pipeline
- `DEFAULT_OPTIONS`: Master table specifying all script defaults, presets, stream options, and keybindings.
- `Config.init()`: Invokes `options.read_options(o, "video_cutter")` to ingest flat user configuration from `video_cutter.conf`. Expands `target_dir` and resolves platform defaults (`~/Videos` or `%USERPROFILE%\Videos`).
- `load_settings()` / `save_settings()`: Reads/writes `.video_cutter_settings.json` in the target directory for user-persisted encoder and format preferences.
- `enforce_compatibility_mode()`: Guarantees MP4/H264/AAC output on startup unless `compatibility_mode` is explicitly disabled by the user.

### 2) Stream classification and stream offsets
- `get_stream_type(url)`: Classifies the playing media as `local_file`, `youtube`, `twitch`, `kick`, `tiktok`, `twitter`, `bilibili`, `vimeo`, `dailymotion`, `nicovideo`, `hls`, `dash`, or generic `remote`.
- Platform offsets (`twitch_offset_start`, `twitch_offset_end`, `kick_offset_start`, `kick_offset_end`) compensate for clock skew when clipping live or VOD streams.

### 3) Command builder and FFmpeg execution
- `Command` class: Wraps command-line argument arrays and execution state, including `-y`/`-n` overwrite flag encapsulation (`Command:set_overwrite`).
- `build_ffmpeg_command`: Assembles FFmpeg arguments for local media, preserving source framerate (`fps`), audio settings, subtitle burn-in filters, and hardware encoders.
- Subtitle burn-in: `get_selected_sub_track` detects active sub tracks, filtering out unsupported image subtitles and escaping paths for FFmpeg filter syntax.
- GIF creation: `build_gif_filter` sets up a two-pass palette filter (`fps`, `scale`, `palettegen`, `paletteuse`).
- Hardware acceleration: `detect_hardware_accel` queries `ffmpeg -encoders` once at startup for NVENC, QSV, VAAPI, VideoToolbox, and AMF, matching the encoder family to the active video codec.

### 4) Remote clipping engine (yt-dlp)
- `process_remote_segment`: Uses `yt-dlp --download-sections` to download the target section into an intermediate `<name>.source.mkv` file.
- Triggers a secondary FFmpeg command to transcode or remux the intermediate into the user's desired preset, format, and filename.
- Intermediate cleanup: Intermediate `.source.mkv` files are automatically removed upon encode completion or failure.

### 5) Queue and merge system
- Segment list: `Segments` table stores queued clips (`start_pos`, `end_pos`).
- Per-source persistence: Saves queue state to `~~/queue_<hash>.json` in MPV's config directory, restored automatically when reloading the file.
- `render_queue`: Processes queued segments sequentially through the async job queue.
- Merge mode: Generates intermediate segments (`_vctemp_*`), writes a temporary concat list (`merge_list_<timestamp>.txt`), runs FFmpeg's concat demuxer, and cleans up all temporary artifacts.

### 6) On-screen overlays and UI
- Status HUD (`h`): ASS overlay rendering active jobs, toggles, stream type, and queue count.
- Timeline bar overlay (`t`): ASS draw overlay showing playback position, cut mark, and queued segment ranges.
- Interactive Settings Menu (`Shift+m`): Modal menu binding `UP`, `DOWN`, `LEFT`, `RIGHT`, `0`-`7`, and `Esc` for in-player adjustments of format, quality presets, codecs, hardware accel, and compatibility mode.
- Help overlay (`?`): Keybinding reference sheet.

### 7) Undo stack
- `push_undo` / `undo_last` (`u`): Multi-level undo stack tracking `set_mark`, `clear_mark`, `set_pending_start`, `clear_pending_start`, and `add_segment`.

---

## Verification procedures

### Automated tests
Run the end-to-end smoke test suite from the repository root:
```bash
bash test/run.sh
```
Test suite covers:
- **T1**: Default cut creates valid MP4, preserves 60 fps source framerate, and retains audio.
- **T2**: Setting empty key in `video_cutter.conf` (`key_toggle_mark=`) disables keybinding.
- **T3**: Non-MP4 saved settings in `.video_cutter_settings.json` survive restart when compatibility mode is off.
- **T4**: `ytdl://` generic remote URL cutting via `yt-dlp` using a mock range-request HTTP server.

### Syntax and static checks
Ensure syntax validity and verify no global variables leaked into the environment:
```bash
luac -p scripts/video-segment-cutter.lua
# In Lua 5.1/LuaJIT:
luac -p -l scripts/video-segment-cutter.lua | grep -E 'SETGLOBAL'
# In Lua 5.2+:
luac -p -l scripts/video-segment-cutter.lua | grep -E 'SETTABUP.*_ENV'
```
No global variable assignments should appear in production code.

### Manual verification sequence
1. Open MPV with local video: confirm init OSD displays script version and hardware acceleration family.
2. Press `c` to set mark, seek forward, press `c`: verify output file is created in target directory.
3. Test quick-cut: verify last N seconds can be extracted cleanly.
4. Test queue mode (`Ctrl+q`, `Shift+s`, `Shift+e`, `r`): verify multiple segments render.
5. Test merge mode (`Ctrl+m`, `r`): verify segments are concatenated and temp files removed.
6. Open Settings Menu (`Shift+m`), alter an option, save settings (`Ctrl+Alt+s`), restart MPV, load settings (`Ctrl+Alt+l`).
7. Test export cuts (`Ctrl+Alt+e`): check generated export text file in target directory.

---

## Documentation contract

Whenever behavior, options, or keybindings change:
- Update `README.md` (features, keybindings, workflows, options).
- Update `script-opts/video_cutter.conf` (defaults, option descriptions, and key mappings).
- Update `AGENTS.md` if internal architecture, lifecycle invariants, or testing procedures change.
- Keep documentation strictly factual; do not claim support for untested or speculative features.