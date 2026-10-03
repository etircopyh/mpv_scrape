#!/usr/bin/env bash
# E2E smoke tests for scripts/video-segment-cutter.lua. Requires: mpv, ffmpeg, python3.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/video-segment-cutter.lua"
WORK="$(mktemp -d /tmp/vctest.XXXXXX)"
OUT="$WORK/out"; CONF="$WORK/conf"; mkdir -p "$OUT" "$CONF/script-opts"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
note() { printf '%s\n' "$*"; }
ok()   { note "PASS: $1"; PASS=$((PASS+1)); }
bad()  { note "FAIL: $1"; FAIL=$((FAIL+1)); }

conf() { printf 'target_dir=%s\n' "$OUT" > "$CONF/script-opts/video_cutter.conf"; }

run_mpv() { # $1=media  $2=scenario  $3=extra conf lines ("")  $4=extra mpv flags ("")
  conf
  if [ -n "$3" ]; then printf '%s\n' "$3" >> "$CONF/script-opts/video_cutter.conf"; fi
  VCT_SCENARIO="$2" VCT_QUIT="${VCT_QUIT:-7}" VCT_YTDL_URL="${VCT_YTDL_URL:-}" timeout 40 mpv --config-dir="$CONF" --vo=null --ao=null \
    --script="$ROOT/test/driver.lua" --script="$SCRIPT" ${4:-} "$1" > "$WORK/mpv.log" 2>&1
}

gen_fixture() { # $1=output path  $2=fps
  ffmpeg -y -loglevel error -f lavfi -i "testsrc2=duration=4:size=320x240:rate=$2" \
    -f lavfi -i "sine=frequency=440:duration=4" -map 0:v -map 1:a \
    -c:v libx264 -preset ultrafast -c:a aac -shortest "$1"
}

VERSION="$(grep -oE 'SCRIPT_VERSION = "[^"]+"' "$SCRIPT" | head -1 | cut -d'"' -f2)"

# ---- T1: default cut preserves source framerate and keeps audio
fixture60="$WORK/t60.mp4"; gen_fixture "$fixture60" 60
run_mpv "$fixture60" cut ""
outfile=$(find "$OUT" -maxdepth 1 -type f ! -name '*.json' | head -1)
fps="$(ffprobe -v error -select_streams v -show_entries stream=avg_frame_rate -of csv=p=0 "$outfile" 2>/dev/null)"
if [ -n "$outfile" ] && [ "${outfile##*.}" = "mp4" ] && [ "$fps" = "60/1" ] \
   && [ -n "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$outfile" 2>/dev/null)" ]; then
  ok "T1 default mp4 + fps preserved (60/1) + audio present"
else
  bad "T1 default mp4 + fps + audio (got ext=${outfile##*.} fps=$fps)"
fi

# ---- T2: key_toggle_mark= disables the c binding
rm -rf "$OUT"; mkdir -p "$OUT"
run_mpv "$fixture60" probe-c "key_toggle_mark=" ""
if [ -z "$(find "$OUT" -maxdepth 1 -type f ! -name '*.json' | head -1)" ]; then
  ok "T2 empty key disables binding"
else
  bad "T2 empty key disables binding (output was produced)"
fi

# ---- T3: saved non-mp4 settings (compatibility_mode=false) survive restart
rm -rf "$OUT"; mkdir -p "$OUT"
cat > "$OUT/.video_cutter_settings.json" <<EOF
{"version":"$VERSION","encoding":{"format":"mkv","video":{"codec":"libx265","bitrate":"","fps":"","crf":23,"preset":"medium"},"audio":{"enabled":true,"codec":"aac","bitrate":"192k"},"gif":{"fps":15,"scale":640,"mode":"auto"},"subtitles":{"enabled":true},"hardware":{"enabled":false},"lossless":false,"apply_filters":true,"audio_only":false,"custom_ffmpeg_args":[]},"output_template":"\$s_\$e.\$x","compatibility_mode":false,"saved_at":"0000-00-00 00:00:00"}
EOF
run_mpv "$fixture60" cut ""
outfile=$(find "$OUT" -maxdepth 1 -type f ! -name '*.json' | head -1)
codec="$(ffprobe -v error -select_streams v -show_entries stream=codec_name -of csv=p=0 "$outfile" 2>/dev/null)"
if [ -n "$outfile" ] && [ "${outfile##*.}" = "mkv" ] && [ "$codec" = "hevc" ]; then
  ok "T3 saved mkv/x265 settings survive"
else
  bad "T3 saved mkv/x265 settings survive (got ext=${outfile##*.} codec=$codec)"
fi

# ---- T4: ytdl://-prefixed generic URL is cut via yt-dlp (skips if not installed)
if command -v yt-dlp >/dev/null 2>&1; then
  rm -rf "$OUT"; mkdir -p "$OUT"
  (cd "$WORK" && exec env PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/test/range_server.py" 18765 >/dev/null 2>&1) &
  SRV=$!
  sleep 1
  VCT_QUIT=25 VCT_YTDL_URL="ytdl://http://127.0.0.1:18765/t60.mp4" VCT_SCENARIO="ytdl-cut" run_mpv "$fixture60" cut "" "--loop-file=inf"
  kill "$SRV" 2>/dev/null
  wait "$SRV" 2>/dev/null
  outfile=$(find "$OUT" -maxdepth 1 -type f ! -name '*.json' | head -1)
  if [ -n "$outfile" ] && ffprobe -v error -show_entries format=format_name -of csv=p=0 "$outfile" >/dev/null 2>&1; then
    ok "T4 ytdl:// generic URL cut"
  else
    bad "T4 ytdl:// generic URL cut (no valid output)"
  fi
else
  note "SKIP: T4 (yt-dlp not installed)"
fi

note ""
note "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]