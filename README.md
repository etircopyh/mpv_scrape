# mpv_scrape - MPV Video Segment Cutter

Advanced MPV script for fast clip extraction from local files and remote streams (YouTube, Twitch, Kick, TikTok, Twitter/X, Bilibili, Vimeo, and more), with queue rendering, merge mode, presets, interactive settings menu, visual timeline overlay, and persistent settings.

> Script file: `scripts/video-segment-cutter.lua`  
> User options file: `script-opts/video_cutter.conf`

---

## What this project does

`mpv_scrape` adds an in-player workflow for creating clips while watching content in MPV:

- Mark start/end and cut immediately (`c` or `Shift+x`)
- Quick-cut preceding playback duration on the fly (e.g. last 30s or 60s) without prior marks
- Queue multiple segments and render in a batch (`Ctrl+q`, `Shift+s`, `Shift+e`, `r`)
- Merge queued segments into a single concatenated video file (`Ctrl+m`)
- Loop preview marked segments before cutting (`Shift+p`)
- On-screen interactive Settings Menu (`Shift+m`) with keyboard navigation
- Visual timeline bar overlay (`t`) displaying playhead, marks, and queued ranges
- Real-time status HUD (`h`), compact state inspector (`i`), and help overlay (`?`)
- Live toggles for audio, audio-only extraction (`Shift+a`), subtitles, GIF mode, lossless mode, and hardware acceleration
- Hardware acceleration auto-detection for NVENC, QSV, VAAPI, VideoToolbox, and AMF
- Built-in encoding presets (`fast`, `balanced`, `quality`, `archive`, `web`, `gif`, `mobile`)
- Remote URL and live stream clipping via `yt-dlp` with stream offset compensation
- Customizable, collision-safe output naming templates (`$f`, `$t`, `$s`, `$e`, `$d`, `$x`, `$p`, `$D`, `$T`, `$r`, `$n`)
- Multi-action undo stack (`u`) for marks and queue operations
- Persistent settings (`Ctrl+Alt+s` / `Ctrl+Alt+l`) saved to `.video_cutter_settings.json`
- Segment timestamp list export (`Ctrl+Alt+e`)
- Automatic or manual reveal of output files/folders (`o`)

---

## Features

- **Local and HLS cutting via FFmpeg**: Fast stream-copy or transcode with preserved source framerate.
- **Remote stream clipping via yt-dlp**: Download and encode segments from YouTube, Twitch, Kick, TikTok, Twitter/X, Bilibili, Vimeo, Dailymotion, NicoVideo, and generic HTTP/HTTPS sources.
- **Queue mode**: Mark multiple segments across playback and batch-render sequentially.
- **Merge mode**: Automatically concatenate queued segments into a unified video with intermediate cleanup.
- **Quick-cut support**: Capture the last N seconds of playback with a single keystroke.
- **Presets**: Quick-switch between `fast`, `balanced`, `quality`, `archive`, `web`, `gif`, and `mobile`.
- **Live toggles**:
  - Audio inclusion (on/off)
  - Audio-only extraction (outputs `.opus`, `.m4a`, `.mp3`, or `.flac`)
  - Subtitle burn-in (embedded and external SRT/ASS with automatic styling)
  - GIF mode (`auto`, `always`, `never`)
  - Lossless mode (stream copy where compatible)
  - Hardware acceleration (auto-detects available GPU encoders)
- **Interactive Settings Menu**: Navigate and alter encoding settings directly on the OSD.
- **Visual timeline overlay**: Bar overlay displaying current position, cut marks, and queued segments.
- **Status overlays**: Real-time HUD overlay (`h`), one-line state query (`i`), and help screen (`?`).
- **Undo history**: Revert accidental marks, pending starts, or queue additions.
- **Persistent queue**: Queue state is preserved per-source in `~~/queue_<hash>.json`.
- **Persistent settings**: Save preferred format, codecs, and toggles across sessions.
- **Collision-safe naming**: Automatic incrementing (`$n`) prevents accidental overwriting.

---

## Requirements

### Required
- [MPV](https://mpv.io/) (v0.33+ recommended)
- [FFmpeg](https://ffmpeg.org/) and `ffprobe` available on system PATH

### Optional (for remote stream clipping)
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) available on system PATH

---

## Installation

1. Copy the script to your MPV scripts directory:
   - Linux/macOS: `~/.config/mpv/scripts/video-segment-cutter.lua`
   - Windows: `%APPDATA%\mpv\scripts\video-segment-cutter.lua`
2. Copy the configuration file to your MPV script-opts directory:
   - Linux/macOS: `~/.config/mpv/script-opts/video_cutter.conf`
   - Windows: `%APPDATA%\mpv\script-opts\video_cutter.conf`
3. Ensure `ffmpeg` and `ffprobe` are installed and reachable in your terminal PATH.
4. (Optional) Install `yt-dlp` for remote URL segment downloading.

In this repository, files are located at:
- `scripts/video-segment-cutter.lua`
- `script-opts/video_cutter.conf`

---

## Quick start

### Instant cut
1. Open a video in MPV.
2. Press `c` to set the start mark.
3. Seek to your desired end point.
4. Press `c` again to cut the segment from mark to current position.

Alternatively, set the mark with `c`, seek to the end point, and press `Shift+x` to execute the cut.

### Quick-cut preceding seconds
Assign a key to `key_quick_cut_last` (or `key_quick_cut_30` / `key_quick_cut_60`) in `video_cutter.conf`. Press the key during playback to immediately save the preceding duration without setting marks first.

---

## Default keybindings

Configured in `script-opts/video_cutter.conf`:

| Key | Action | Description |
|---|---|---|
| `c` | Toggle mark / cut | First press sets mark; second press cuts mark to current position |
| `Shift+x` | Execute cut | Cut from mark to current position |
| `C` | Clear mark | Clears active mark, pending queue start, and loop preview |
| `Shift+p` | Preview segment | Loops playback between mark and current position (A-B loop) |
| `x` | Cancel job | Aborts current running cut or last job |
| `Ctrl+q` | Toggle queue mode | Enables queueing multiple segments for batch processing |
| `Shift+s` | Queue: set start | Marks start position of a queued segment |
| `Shift+e` | Queue: set end | Marks end position and adds segment to queue |
| `r` | Render queue | Starts sequential rendering of all queued segments |
| `Ctrl+m` | Toggle merge mode | When rendering queue, concatenates segments into one file |
| `a` | Toggle audio | Enables or disables audio stream in output |
| `Shift+a` | Toggle audio-only | Extracts audio stream only (e.g. `.opus`, `.m4a`, `.mp3`) |
| `Ctrl+s` | Toggle subtitles | Burns active subtitles into output |
| `g` | Toggle GIF mode | Cycles GIF generation (`auto`, `always`, `never`) |
| `Ctrl+l` | Toggle lossless mode | Enables stream copy when codecs permit |
| `H` | Toggle hardware accel | Toggles GPU-accelerated encoding (NVENC, QSV, VAAPI, etc.) |
| `p` | Cycle preset | Cycles through encoding presets (`fast`, `balanced`, `quality`, etc.) |
| `Shift+m` | Toggle settings menu | Opens on-screen interactive configuration menu |
| `t` | Toggle timeline overlay | Displays visual timeline bar with marks and segments |
| `i` | Compact state | Displays one-line summary of current cutter state |
| `h` | Status HUD | Toggles full-screen status HUD overlay |
| `?` | Help overlay | Displays keybinding help sheet |
| `u` | Undo | Reverts last mark, pending start, or queued segment |
| `o` | Open output | Reveals last created output file or folder |
| `Ctrl+Alt+s` | Save settings | Persists encoding options to `.video_cutter_settings.json` |
| `Ctrl+Alt+l` | Load settings | Reloads saved options from `.video_cutter_settings.json` |
| `Ctrl+Alt+e` | Export cuts | Exports queued segment timestamps to text file |

To disable any keybinding, set its value to empty in `video_cutter.conf` (e.g. `key_toggle_mark=`).

### Optional quick-cut shortcuts

Unbound by default in `video_cutter.conf`:

| Option | Default Value | Description |
|---|---|---|
| `key_quick_cut_last` | `""` | Cuts the preceding `quick_cut_seconds` (default 30s) |
| `key_quick_cut_30` | `""` | Cuts the preceding 30 seconds of playback |
| `key_quick_cut_60` | `""` | Cuts the preceding 60 seconds of playback |

### Settings menu navigation

When the settings menu is open (`Shift+m`):

| Key | Action |
|---|---|
| `UP` / `DOWN` | Navigate through menu options |
| `LEFT` / `RIGHT` | Cycle the value of the selected option |
| `1` - `7` | Select option by number |
| `0` / `Esc` / `Shift+m` | Close settings menu |

Configurable items in the settings menu:
1. **Format**: `mp4`, `mkv`, `webm`
2. **Quality (Preset)**: `fast`, `balanced`, `quality`, `archive`, `web`, `mobile`
3. **Video Codec**: `libx264`, `libx265`, `copy`
4. **Audio Codec**: `aac`, `opus`, `copy`
5. **Hardware Accel**: `off`, `auto`
6. **Max Quality (Remote)**: `720`, `1080`, `1440`, `2160`
7. **Audio Only**: `off`, `on`
8. **Compatibility**: `off`, `on`

---

## Workflows

### 1) Instant single cut
- Press `c` at desired start time (OSD confirms mark).
- Seek to desired end time.
- Press `c` again to cut.
- (Or press `Shift+x` to cut explicitly from mark to current playhead).

### 2) Preview segment before cutting
- Press `c` at start time.
- Seek to end time.
- Press `Shift+p` to enter loop preview (plays the selected range continuously).
- If satisfied, press `Shift+x` to execute the cut.
- Press `C` to cancel the preview loop.

### 3) Quick-cut preceding playback
- Configure a key in `video_cutter.conf`: `key_quick_cut_last=F10`.
- While watching a stream or video, press `F10`.
- The script immediately cuts the preceding 30 seconds (configurable via `quick_cut_seconds`).

### 4) Queue multiple segments
- Press `Ctrl+q` to turn on Queue mode.
- Seek to start of first segment, press `Shift+s`.
- Seek to end of first segment, press `Shift+e` (segment added to queue).
- Repeat for subsequent segments.
- Press `r` to render all segments in sequence.

### 5) Queue and merge into a single video
- Press `Ctrl+q` to enable Queue mode.
- Press `Ctrl+m` to enable Merge mode.
- Add segments using `Shift+s` and `Shift+e`.
- Press `r` to render. The script generates intermediate clips, concatenates them via FFmpeg concat demuxer, and cleans up temporary files.

### 6) Interactive settings adjustments
- Press `Shift+m` to open the Settings Menu.
- Use `UP` and `DOWN` arrows to highlight a setting (e.g. Video Codec or Format).
- Use `LEFT` and `RIGHT` arrows to cycle values.
- Press `Esc` or `Shift+m` to close.
- To make settings persist across sessions, press `Ctrl+Alt+s`.

### 7) Audio-only extraction
- Press `Shift+a` to toggle Audio Only mode.
- Set mark (`c`) and cut (`c` or `Shift+x`).
- Output file extension automatically matches the chosen audio codec (`.m4a`, `.opus`, `.mp3`, or `.flac`).

### 8) Exporting segment timestamps
- Queue desired segments (`Shift+s` / `Shift+e`).
- Press `Ctrl+Alt+e`.
- A text file containing formatted segment start, end, and duration timestamps is written to `<target_dir>/video_cutter_export_YYYYMMDD_HHMMSS.txt`.

### 9) Undoing actions
- Press `u` to revert the last user action in reverse chronological order:
  - Clears accidentally placed marks
  - Restores previously cleared marks
  - Removes the last added queue segment
  - Restores pending queue start positions

---

## Presets reference

| Preset | Video Codec | FFmpeg Preset | CRF / Bitrate | Format | Intended Use |
|---|---|---|---|---|---|
| `fast` | `libx264` | `ultrafast` | CRF 28 | `mp4` | Fastest encoding, draft cuts |
| `balanced` | `libx264` | `veryfast` | CRF 23 | `mp4` | Default; balanced speed and file size |
| `quality` | `libx265` | `slow` | CRF 18 | `mkv` | High-fidelity archival encoding |
| `archive` | `ffv1` | N/A | Lossless | `mkv` | Master/lossless preservation |
| `web` | `libx264` | `medium` | 2000k ABR | `mp4` | Target bandwidth for web sharing |
| `gif` | N/A | N/A | 15 fps, scale 480 | `gif` | Animated GIF with two-pass palette |
| `mobile` | `libx264` | `fast` | CRF 26, 1500k ABR | `mp4` | Compact size for mobile/messaging |

Cycle presets during playback with `p`, or choose directly in the Settings Menu (`Shift+m`).

---

## Output behavior and naming templates

### Default output directories
- Linux/macOS: `~/Videos/`
- Windows: `%USERPROFILE%\Videos\`

### Default filename template
`$f_$s_$e.$x`

### Template variables
| Variable | Description | Example |
|---|---|---|
| `$f` | Source filename without extension | `my_video` |
| `$t` | Media title (sanitized) | `Stream_Episode_1` |
| `$s` | Segment start timestamp (`HH_MM_SS`) | `00_01_30` |
| `$e` | Segment end timestamp (`HH_MM_SS`) | `00_02_15` |
| `$d` | Segment duration (`HH_MM_SS`) | `00_00_45` |
| `$x` | Target file extension | `mp4`, `mkv`, `gif`, `m4a` |
| `$p` | Active preset name | `balanced` |
| `$D` | Current date (`YYYYMMDD`) | `20261003` |
| `$T` | Current time (`HHMMSS`) | `143000` |
| `$r` | Random 4-digit numeric suffix | `4821` |
| `$n` | Collision index (1, 2, 3...) | `2` |

### Collision prevention
When `naming.auto_increment` is enabled (default), the script automatically prevents filename collisions. If an output file already exists, an incrementing index (`_$n`) is attached to produce a unique name without overwriting prior clips.

---

## Configuration options (`video_cutter.conf`)

Configuration is read from `script-opts/video_cutter.conf`.

```conf
# Custom output directory (leave blank for ~/Videos or %USERPROFILE%\Videos)
target_dir=

# Executable paths (if not in system PATH)
ffmpeg_path=ffmpeg
ffprobe_path=ffprobe

# Compatibility mode: enforces universal MP4/H264/AAC output on startup
compatibility_mode=yes

# Remote stream compensation offsets (seconds)
twitch_offset_start=63
twitch_offset_end=61
kick_offset_start=0
kick_offset_end=0

# Quick-cut duration (seconds)
quick_cut_seconds=30
```

### Keybinding configuration
All keybindings are configurable in `video_cutter.conf` using the `key_<action>=<key>` syntax. Setting an empty value disables the binding:
```conf
key_toggle_mark=c
key_execute_cut=Shift+x
key_clear_mark=C
key_preview_segment=Shift+p
key_cancel_job=x
key_toggle_queue=Ctrl+q
key_set_start=Shift+s
key_set_end=Shift+e
key_render_queue=r
key_toggle_merge=Ctrl+m
key_toggle_audio=a
key_toggle_audio_only=Shift+a
key_toggle_subs=Ctrl+s
key_toggle_gif=g
key_toggle_lossless=Ctrl+l
key_toggle_hardware=H
key_cycle_preset=p
key_settings_menu=Shift+m
key_toggle_timeline=t
key_show_state=i
key_show_hud=h
key_show_help=?
key_undo=u
key_open_output=o
key_save_settings=Ctrl+Alt+s
key_load_settings=Ctrl+Alt+l
key_export_cuts=Ctrl+Alt+e

# Optional quick-cut bindings (unbound by default)
key_quick_cut_last=
key_quick_cut_30=
key_quick_cut_60=
```

---

## Remote clipping and streaming notes

For remote URLs (`http(s)://`, YouTube, Twitch, Kick, TikTok, Twitter/X, Bilibili, etc.), `mpv_scrape` utilizes `yt-dlp` to download the specific section (`--download-sections`):

- **Prerequisite**: `yt-dlp` must be installed and executable.
- **Offset compensation**: Live and VOD streams from platforms such as Twitch often have playback clock skews. Tunable offset variables (`twitch_offset_start`, `twitch_offset_end`, `kick_offset_start`, `kick_offset_end`) align cuts accurately.
- **Two-pass pipeline**: yt-dlp fetches the section to an intermediate `<name>.source.mkv` file. FFmpeg then transcodes or trims the intermediate according to your active preset and settings, automatically removing the intermediate file when finished.
- **Queue support**: Remote segments can be queued and batch-rendered like local files.

---

## Runtime files created

| File Pattern | Location | Purpose | Cleanup Policy |
|---|---|---|---|
| `queue_<hash>.json` | MPV home directory (`~~/`) | Persistent segment queue per source file | Persisted until cleared by user |
| `.video_cutter_settings.json` | Output directory (`target_dir`) | Persisted user settings from `Ctrl+Alt+s` | User managed |
| `video_cutter_export_*.txt` | Output directory (`target_dir`) | Exported list of cut timestamps (`Ctrl+Alt+e`) | Permanent export record |
| `merge_list_<timestamp>.txt` | Output directory (`target_dir`) | Concat list file for FFmpeg merge operations | Deleted immediately after merge |
| `_vctemp_*` | Output directory (`target_dir`) | Intermediate segment files generated during merge | Deleted immediately after merge |
| `<name>.source.mkv` | Output directory (`target_dir`) | Intermediate section download from yt-dlp | Deleted immediately after final encode |

---

## Automated testing

The repository includes an end-to-end smoke test suite verifying script initialization, key unbinding, settings persistence, and remote extraction:

```bash
bash test/run.sh
```

Tests run headless using MPV dummy VO/AO drivers with synthetic media fixtures.

---

## Troubleshooting

### "FFmpeg not found"
Ensure FFmpeg is installed and accessible via PATH, or set `ffmpeg_path=/path/to/ffmpeg` in `video_cutter.conf`.

### "yt-dlp not available"
Install `yt-dlp` and add it to your PATH for remote URL cutting.

### Output file already exists
By default, the script automatically appends an incrementing index (`_$n`) so existing clips are never overwritten. If desired, you can customize your output template in `video_cutter.conf`.

### Leftover `.source.mkv` files in output folder
These are intermediate downloads from `yt-dlp` during remote clipping. They are automatically deleted when encoding succeeds. If MPV is closed or terminated mid-render, leftover files can be safely deleted.

### Merge mode failed
- Merge mode requires at least two valid queued segments.
- Check MPV console logs (`~` key in MPV) for FFmpeg concat demuxer warnings or codec mismatches.

---

## Version

Script header reports: **v3.4.1**.

---

## License

Use according to your project and repository licensing terms.