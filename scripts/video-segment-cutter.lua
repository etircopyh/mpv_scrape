-- ============================================================================
-- Video Segment Cutter for MPV
-- Version: 3.4.1
-- Description: Advanced video cutting with async processing, hardware accel,
--              queue management, remote stream support, and customizable templates
-- ============================================================================

local msg = require("mp.msg")
local utils = require("mp.utils")
local options = require("mp.options")
local assdraw = require("mp.assdraw")

-- luacheck: globals mp
---@diagnostic disable-next-line: undefined-field
local mp = _G.mp

-- ============================================================================
-- CONSTANTS AND CONFIGURATION
-- ============================================================================

local is_windows = package.config:sub(1, 1) == "\\"
local SCRIPT_VERSION = "3.4.1"
local win_userprofile = os.getenv("USERPROFILE")
  or (os.getenv("HOMEDRIVE") and os.getenv("HOMEPATH") and os.getenv("HOMEDRIVE") .. os.getenv("HOMEPATH"))
  or os.getenv("TEMP")
  or "."

-- Default options optimized for maximum compatibility (Telegram, Discord, Mobile)
local DEFAULT_OPTIONS = {
  paths = {
    ffmpeg_path = "ffmpeg",
    ffprobe_path = "ffprobe",
    win_target_dir = win_userprofile and win_userprofile .. "\\Videos\\" or "C:\\Users\\Videos\\",
    unix_target_dir = "~/Videos/",
  },
  output = {
    template = "$f_$s_$e.$x",
    auto_open = false,
    open_file = false,
  },
  encoding = {
    cut_pos = nil,
    format = "mp4",
    video = {
      codec = "libx264",
      bitrate = "", -- empty = CRF mode; set e.g. "6000k" to force ABR
      fps = "", -- empty = preserve source framerate; set e.g. "60" to force CFR
      crf = 23,
      preset = "medium",
    },
    audio = {
      enabled = true,
      codec = "aac",
      bitrate = "192k",
    },
    gif = {
      fps = 15,
      scale = 640,
      mode = "auto",
    },
    subtitles = {
      enabled = true,
    },
    hardware = {
      enabled = false,
      decoder = "auto",
      encoder = "h264_nvenc",
      device = "",
      quality_preset = "fast",
    },
    lossless = false, -- Disabled by default for max compatibility
    apply_filters = true,
    audio_only = false,
    custom_ffmpeg_args = {},
  },
  presets = {
    fast = { vcodec = "libx264", preset = "ultrafast", crf = 28, format = "mp4" },
    balanced = { vcodec = "libx264", preset = "veryfast", crf = 23, format = "mp4" },
    quality = { vcodec = "libx265", preset = "slow", crf = 18, format = "mkv" },
    archive = { vcodec = "ffv1", format = "mkv" },
    web = { vcodec = "libx264", bitrate = "2000k", format = "mp4" },
    gif = { mode = "always", fps = 15, scale = 480 },
    mobile = { vcodec = "libx264", preset = "fast", crf = 26, format = "mp4", bitrate = "1500k" },
  },
  source_defaults = {
    local_file = { format = "mp4", lossless = false },
    youtube = { format = "mp4", max_quality = "1080", lossless = false },
    twitch = { format = "mp4", lossless = false },
    kick = { format = "mp4", lossless = false },
    hls = { format = "ts", lossless = false },
    remote = { format = "mp4", lossless = false },
  },
  youtube = {
    max_quality = "1080",
    dlp_args = {},
    sub_langs = "en",
    twitch_offset_start = 63,
    twitch_offset_end = 61,
    kick_offset_start = 0,
    kick_offset_end = 0,
  },
  naming = {
    auto_increment = true,
  },
  flags = {
    overwrite = false,
    debug = false,
    directory_ready = true,
    ffmpeg_available = true,
    ytdlp_available = true,
    dependencies_checked = false,
    queue_mode = false,
    merge_mode = false,
  },
  hud = {
    enabled = true,
    update_interval = 1.0,
  },
  compatibility_mode = true, -- Forces mp4/h264/aac on startup
  target_dir = "",
  ffmpeg_path = "",
  ffprobe_path = "",
  twitch_offset_start = 63,
  twitch_offset_end = 61,
  kick_offset_start = 0,
  kick_offset_end = 0,
  key_toggle_mark = "c",
  key_cancel_job = "x",
  key_toggle_audio = "a",
  key_toggle_subs = "Ctrl+s",
  key_toggle_gif = "g",
  key_toggle_lossless = "Ctrl+l",
  key_toggle_hardware = "H",
  key_clear_mark = "C",
  key_show_state = "i",
  key_show_hud = "h",
  key_show_help = "?",
  key_cycle_preset = "p",
  key_toggle_merge = "Ctrl+m",
  key_toggle_queue = "Ctrl+q",
  key_toggle_timeline = "t",
  key_settings_menu = "Shift+m",
  key_set_start = "Shift+s",
  key_set_end = "Shift+e",
  key_execute_cut = "Shift+x",
  key_render_queue = "r",
  key_undo = "u",
  key_open_output = "o",
  key_save_settings = "Ctrl+Alt+s",
  key_load_settings = "Ctrl+Alt+l",
  key_export_cuts = "Ctrl+Alt+e",
  key_toggle_audio_only = "Shift+a",
  key_preview_segment = "Shift+p",
  -- Seconds captured by the (optional) key_quick_cut_last binding.
  quick_cut_seconds = 30,
  -- Optional quick-cut bindings (empty = unbound). When bound, the keys cut
  -- the last N seconds of playback without needing a manual mark.
  key_quick_cut_last = "",
  key_quick_cut_30 = "",
  key_quick_cut_60 = "",
}

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function deep_copy(orig)
  if type(orig) ~= "table" then
    return orig
  end
  local copy = {}
  for k, v in pairs(orig) do
    copy[deep_copy(k)] = deep_copy(v)
  end
  return copy
end

local function table_merge(base, override)
  local result = deep_copy(base)
  for k, v in pairs(override or {}) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = table_merge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

local function copy_array(arr)
  local result = {}
  for i, v in ipairs(arr or {}) do
    result[i] = v
  end
  return result
end

local WINDOWS_RESERVED_NAMES = {
  CON = 1, PRN = 1, AUX = 1, NUL = 1,
  COM1 = 1, COM2 = 1, COM3 = 1, COM4 = 1, COM5 = 1,
  COM6 = 1, COM7 = 1, COM8 = 1, COM9 = 1,
  LPT1 = 1, LPT2 = 1, LPT3 = 1, LPT4 = 1, LPT5 = 1,
  LPT6 = 1, LPT7 = 1, LPT8 = 1, LPT9 = 1,
}

local function sanitize_filename(name)
  if not name or name == "" then
    return "clip"
  end
  name = name:gsub('[<>:"/\\|?*%c]', "_"):gsub("%s+", "_"):gsub("_+", "_"):sub(1, 200)
  if is_windows then
    local base = name:match("^([^.]+)") or name
    if WINDOWS_RESERVED_NAMES[base:upper()] then
      name = "_" .. name
    end
  end
  return name
end

local function format_timestamp(seconds, include_ms)
  if not seconds then
    return "--:--:--"
  end
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local secs = seconds % 60
  if include_ms == true then
    return string.format("%02d:%02d:%05.2f", hours, minutes, secs)
  else
    return string.format("%02d:%02d:%02d", hours, minutes, math.floor(secs))
  end
end

local function format_duration(seconds)
  if not seconds then
    return "--"
  end
  if seconds < 60 then
    return string.format("%.1fs", seconds)
  elseif seconds < 3600 then
    return string.format("%dm %ds", math.floor(seconds / 60), math.floor(seconds % 60))
  else
    return string.format("%dh %dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
  end
end

-- ============================================================================
-- OPTIONS INITIALIZATION
-- ============================================================================

local o = deep_copy(DEFAULT_OPTIONS)

local Logger = {}
local Config = {}

function Config.init()
  o = deep_copy(DEFAULT_OPTIONS)
  options.read_options(o, "video_cutter", function(list)
    Logger.info("Options updated: " .. utils.to_string(list))
  end)

  if o.ffmpeg_path and o.ffmpeg_path ~= "" then
    o.paths.ffmpeg_path = o.ffmpeg_path
  end
  if o.ffprobe_path and o.ffprobe_path ~= "" then
    o.paths.ffprobe_path = o.ffprobe_path
  end
  if o.twitch_offset_start ~= nil and o.twitch_offset_start ~= "" then
    o.youtube.twitch_offset_start = tonumber(o.twitch_offset_start) or o.youtube.twitch_offset_start
  end
  if o.twitch_offset_end ~= nil and o.twitch_offset_end ~= "" then
    o.youtube.twitch_offset_end = tonumber(o.twitch_offset_end) or o.youtube.twitch_offset_end
  end
  if o.kick_offset_start ~= nil and o.kick_offset_start ~= "" then
    o.youtube.kick_offset_start = tonumber(o.kick_offset_start) or o.youtube.kick_offset_start
  end
  if o.kick_offset_end ~= nil and o.kick_offset_end ~= "" then
    o.youtube.kick_offset_end = tonumber(o.kick_offset_end) or o.youtube.kick_offset_end
  end

  if not o.target_dir or o.target_dir == "" then
    o.target_dir = is_windows and o.paths.win_target_dir or o.paths.unix_target_dir
  end
  local ok, expanded = pcall(function()
    return mp.command_native({ "expand-path", o.target_dir })
  end)
  if ok and expanded then
    o.target_dir = expanded
  else
    Logger.warn("Failed to expand target_dir path, using raw value: " .. tostring(o.target_dir))
  end

  if not utils.file_info(o.target_dir) then
    local mkdir_cmd
    if is_windows then
      mkdir_cmd = { "cmd", "/c", "mkdir", o.target_dir }
    else
      mkdir_cmd = { "mkdir", "-p", o.target_dir }
    end
    local res = mp.command_native({
      name = "subprocess",
      args = mkdir_cmd,
      playback_only = false,
      capture_stdout = true,
      capture_stderr = true,
    })
    if res and res.status == 0 then
      o.flags.directory_ready = true
      Logger.info("Created target directory: " .. o.target_dir)
    else
      if utils.file_info(o.target_dir) then
        o.flags.directory_ready = true
      else
        o.flags.directory_ready = false
        Logger.error("Failed to create target directory: " .. o.target_dir)
      end
    end
  else
    o.flags.directory_ready = true
  end
end

-- ============================================================================
-- STATE VARIABLES
-- ============================================================================

local CurrentPreset = nil
local HardwareAccelDetected = nil
local HelpOverlayVisible = false
local HelpOverlayTimer = nil
local HudOverlay = nil
local HudTimer = nil
local MessageOverlay = nil
local MessageTimer = nil
local PendingSegmentStart = nil
local Segments = {}
local JobQueue = nil
local UndoStack = {}
local LastOutputPath = nil
local TimelineOverlay = {
  overlay_id = nil,
  enabled = false,
  observers_added = false,
  last_update_time = 0,
  update_interval = 0.1,
  last_mark_pos = nil,
  last_segment_count = -1,
  last_queue_mode = false,
}
local save_queue
local load_queue
local select_setting
local apply_preset
local open_output_folder
local render_hud
local hide_status_hud
local process_remote_segment
local cut_video
-- Named OSD-size observers are defined near init but unobserved from
-- cleanup (defined earlier), so forward-declare them here.
local on_osd_width_change
local on_osd_height_change
-- Hardware-accel helpers are defined later (after detect_hardware_accel) but
-- called from build_ffmpeg_command / remote encode, so forward-declare them.
local HardwareAccelFamily = nil
local HardwareAccelEncoders = nil
local hardware_encoder_for
local detect_hardware_accel

local State = {
  processing = false,
  progress = 0,
  current_job_id = nil,
  last_job_id = nil,
  queue_rendering = false,
  settings_manually_changed = false,
}

-- ============================================================================
-- LOGGING SYSTEM
-- ============================================================================

local LOG_LEVELS = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
local CURRENT_LOG_LEVEL = LOG_LEVELS.INFO

local function log(level, message)
  if LOG_LEVELS[level] >= CURRENT_LOG_LEVEL then
    msg[level:lower()](message)
  end
end

local function log_debug(msg_str)
  log("DEBUG", msg_str)
end
local function log_info(msg_str)
  log("INFO", msg_str)
end
local function log_warn(msg_str)
  log("WARN", msg_str)
end
local function log_error(msg_str)
  log("ERROR", msg_str)
end

Logger.debug = log_debug
Logger.info = log_info
Logger.warn = log_warn
Logger.error = log_error
-- ============================================================================
-- CONFIG ACCESSORS (enforce compatibility_mode as a runtime invariant)
-- ============================================================================

-- Whether config was changed by an explicit user action (key/menu/preset),
-- vs. silently loaded at startup or applied per-source.
local function mark_manually_changed()
  State.settings_manually_changed = true
end

-- Compatibility mode defaults to mp4/h264/aac on startup and disables lossless.
-- When active, selecting an alternative format or codec automatically disables
-- compatibility mode and applies the user's choice.
local function enforce_compatibility_mode()
  if not o.compatibility_mode then
    return
  end
  o.encoding.lossless = false
  o.encoding.format = "mp4"
  o.encoding.video.codec = "libx264"
  o.encoding.audio.codec = "aac"
end

local function set_format(value)
  if value == nil or value == "" then
    return
  end
  if o.compatibility_mode and value ~= "mp4" then
    o.compatibility_mode = false
    Logger.info(string.format("compatibility_mode disabled by format selection '%s'", value))
  end
  o.encoding.format = value
  mark_manually_changed()
end

local function set_video_codec(value)
  if value == nil or value == "" then
    return
  end
  if o.compatibility_mode and value ~= "libx264" then
    o.compatibility_mode = false
    Logger.info(string.format("compatibility_mode disabled by video codec selection '%s'", value))
  end
  o.encoding.video.codec = value
  mark_manually_changed()
end

local function set_audio_codec(value)
  if value == nil or value == "" then
    return
  end
  if o.compatibility_mode and value ~= "aac" then
    o.compatibility_mode = false
    Logger.info(string.format("compatibility_mode disabled by audio codec selection '%s'", value))
  end
  o.encoding.audio.codec = value
  mark_manually_changed()
end

local function set_lossless(value)
  if value == nil then
    return
  end
  if o.compatibility_mode and value == true then
    o.compatibility_mode = false
    Logger.info("compatibility_mode disabled by lossless selection")
  end
  o.encoding.lossless = value
  mark_manually_changed()
end

local function set_audio_only(value)
  o.encoding.audio_only = value and true or false
  mark_manually_changed()
end

Config.set_format = set_format
Config.set_video_codec = set_video_codec
Config.set_audio_codec = set_audio_codec
Config.set_lossless = set_lossless
Config.set_audio_only = set_audio_only
Config.enforce_compatibility_mode = enforce_compatibility_mode
Config.mark_manually_changed = mark_manually_changed

-- ============================================================================
-- PROPERTY HELPERS
-- ============================================================================

local function get_property(prop, default)
  return mp.get_property(prop, default or "")
end

local function get_property_number(prop, default)
  return mp.get_property_number(prop, default or 0)
end

local function get_stream_type(url)
  url = url or get_property("path") or ""
  url = url:gsub("^ytdl://", "")
  if url:match("twitch%.tv") then
    return "twitch"
  end
  if url:match("kick%.com") then
    return "kick"
  end
  if url:match("youtube%.com") or url:match("youtu%.be") then
    return "youtube"
  end
  if url:match("facebook%.com") or url:match("fb%.watch") or url:match("fb%.gg") then
    return "facebook"
  end
  if url:match("tiktok%.com") or url:match("vm%.tiktok%.com") then
    return "tiktok"
  end
  if url:match("twitter%.com") or url:match("//x%.com") or url:match("//t%.co") then
    return "twitter"
  end
  if url:match("bilibili%.com") or url:match("b23%.tv") then
    return "bilibili"
  end
  if url:match("vimeo%.com") then
    return "vimeo"
  end
  if url:match("dailymotion%.com") then
    return "dailymotion"
  end
  if url:match("nicovideo%.jp") then
    return "nicovideo"
  end
  if url:match("%.m3u8$") or url:match("%.m3u8%?") then
    return "hls"
  end
  if url:match("%.mpd$") or url:match("%.mpd%?") or url:match("/dash/") then
    return "dash"
  end
  if url:match("^https?://") then
    return "remote"
  end
  return "local_file"
end

local function is_live_stream()
  local duration = mp.get_property_number("duration")
  if duration and duration > 0 then
    return false
  end
  local stream_type = get_stream_type()
  local path = get_property("path") or ""
  local is_remote = stream_type ~= "local_file"
  if not is_remote then
    return false
  end
  local is_live_url = path:match("twitch%.tv")
    or path:match("kick%.com")
    or (path:match("youtube%.com") and path:match("/live/"))
    or (path:match("youtu%.be") and path:match("/live/"))
  if is_live_url then
    return true
  end
  return false
end

local function get_stream_uptime()
  local duration = get_property_number("duration")
  if duration and duration > 0 then
    return nil
  end
  return get_property_number("time-pos")
end

local function should_make_gif()
  return o.encoding.gif.mode == "always" or (o.encoding.gif.mode == "auto" and not o.encoding.audio.enabled)
end

local function should_make_audio_only()
  return o.encoding.audio_only
end

local function ass_escape(text)
  text = tostring(text or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub("{", "\\{")
  text = text:gsub("}", "\\}")
  text = text:gsub("\n", "\\N")
  return text
end

local function ensure_message_overlay()
  if not MessageOverlay then
    MessageOverlay = mp.create_osd_overlay("ass-events")
  end
end

local function clear_message_overlay()
  if MessageTimer then
    MessageTimer:kill()
    MessageTimer = nil
  end
  if MessageOverlay then
    MessageOverlay.data = ""
    MessageOverlay:update()
  end
end

local OSD_CACHE = { w = 1280, h = 720 }

local function osd(str, duration)
  local text = tostring(str or "")
  if text == "" then
    clear_message_overlay()
    return
  end

  ensure_message_overlay()

  local timeout = duration
  if timeout == nil then
    timeout = 3
  end

  local osd_w, osd_h = OSD_CACHE.w, OSD_CACHE.h
  local is_multiline = text:find("\n", 1, true) ~= nil
  local font_size, align, pos_x, pos_y, wrap_mode

  if is_multiline then
    font_size = math.max(36, math.floor(osd_h * 0.038))
    align = 7
    pos_x = math.floor(osd_w * 0.04)
    pos_y = math.floor(osd_h * 0.07)
    wrap_mode = 0
  else
    font_size = math.max(42, math.floor(osd_h * 0.048))
    align = 8
    pos_x = math.floor(osd_w / 2)
    pos_y = math.floor(osd_h * 0.07)
    wrap_mode = 2
  end

  local border = string.format("%.1f", math.max(3.2, font_size * 0.11))
  local shadow = string.format("%.1f", math.max(1.8, font_size * 0.06))
  local styled = string.format(
    "{\\an%d\\pos(%d,%d)\\q%d\\fs%d\\bord%s\\shad%s\\fsp0\\1c&HFFFFFF&\\3c&H101010&\\4c&H101010&}%s",
    align,
    pos_x,
    pos_y,
    wrap_mode,
    font_size,
    border,
    shadow,
    ass_escape(text)
  )

  local overlay = MessageOverlay
  if overlay then
    overlay.data = styled
    overlay.res_x = osd_w
    overlay.res_y = osd_h
    overlay.z = 1200
    overlay:update()
  end

  if MessageTimer then
    MessageTimer:kill()
    MessageTimer = nil
  end

  if timeout > 0 then
    MessageTimer = mp.add_timeout(timeout, clear_message_overlay)
  end
end

local function key_value(option_name, fallback)
  local value = o[option_name]
  if type(value) == "string" then
    if value == "" or value == "no" or value == "disabled" then
      return ""
    end
    return value
  end
  return fallback
end

local function mode_status_text()
  local queue_text = o.flags.queue_mode and "ON" or "OFF"
  local merge_text = o.flags.merge_mode and "ON" or "OFF"
  return string.format("Queue=%s | Merge=%s | Segments=%d", queue_text, merge_text, #Segments)
end

-- ============================================================================
-- DESKTOP NOTIFICATIONS
-- ============================================================================

-- Escape a string for safe interpolation into a single-quoted PowerShell
-- command string: ' -> '' (PowerShell single-quote escape).
local function ps_single_quote_escape(s)
  return (tostring(s or "")):gsub("'", "''")
end

-- Escape a string for safe interpolation into a double-quoted osascript
-- string: " -> \" and \ -> \\.
local function osa_double_quote_escape(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  return s
end

-- Probe for a desktop notification tool once, not on every job completion.
-- command_exists handles both Lua 5.1 (numeric status) and 5.2+ (boolean).
local cached_notify_tool = nil -- nil = not probed, false = none available

local function command_exists(cmd_name)
  local ok = os.execute("command -v " .. cmd_name .. " >/dev/null 2>&1")
  return ok == true or ok == 0
end

local function detect_notify_tool()
  if cached_notify_tool == nil then
    if command_exists("notify-send") then
      cached_notify_tool = "notify-send"
    elseif command_exists("osascript") then
      cached_notify_tool = "osascript"
    else
      cached_notify_tool = false
    end
  end
  return cached_notify_tool
end

local function send_notification(title, message)
  local cmd = nil
  title = tostring(title or "")
  message = tostring(message or "")
  if is_windows then
    cmd = {
      "powershell",
      "-NoProfile",
      "-Command",
      string.format(
        "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); $n = New-Object System.Windows.Forms.NotifyIcon; $n.Icon = [System.Drawing.SystemIcons]::Information; $n.Visible = $true; $n.ShowBalloonTip(3000, '%s', '%s', [System.Windows.Forms.ToolTipIcon]::Info); Start-Sleep -Milliseconds 3200; $n.Dispose()",
        ps_single_quote_escape(title),
        ps_single_quote_escape(message)
      ),
    }
  else
    local tool = detect_notify_tool()
    if tool == "notify-send" then
      cmd = { "notify-send", title, message }
    elseif tool == "osascript" then
      cmd = {
        "osascript",
        "-e",
        string.format(
          'display notification "%s" with title "%s"',
          osa_double_quote_escape(message),
          osa_double_quote_escape(title)
        ),
      }
    end
  end

  if cmd then
    mp.command_native({ name = "subprocess", args = cmd, playback_only = false, detach = true })
  end
end

-- ============================================================================
-- COMMAND BUILDER CLASS
-- ============================================================================

local Command = {}
Command.__index = Command

function Command:new(name)
  assert(type(name) == "string" and name ~= "", "Command name must be a non-empty string")
  return setmetatable({
    name = name,
    arguments = { name },
  }, self)
end

function Command:arg(...)
  for _, v in ipairs({ ... }) do
    if v ~= nil and tostring(v) ~= "" then
      table.insert(self.arguments, tostring(v))
    end
  end
  return self
end

function Command:set_overwrite(enabled)
  local found = false
  for i, arg in ipairs(self.arguments) do
    if arg == "-n" or arg == "-y" then
      self.arguments[i] = enabled and "-y" or "-n"
      found = true
    end
  end
  if not found then
    table.insert(self.arguments, enabled and "-y" or "-n")
  end
  return self
end

function Command:run(opts, callback)
  if type(opts) == "function" and callback == nil then
    callback = opts
    opts = nil
  end
  opts = opts or {}

  local command_args = copy_array(self.arguments)

  if o.flags.debug then
    Logger.info("Executing command: " .. table.concat(command_args, " "))
  end

  local job_queue = JobQueue
  if not job_queue then
    if callback then
      callback(nil, { success = false, error = "job queue unavailable", status = -1 })
    end
    return nil
  end

  local job_id = job_queue:add_job({
    kind = opts.job_type or "system",
    operation = opts.operation or self.name,
    output_path = opts.output_path,
    is_intermediate = opts.is_intermediate or false,
    progress = 0,
    duration = opts.duration,
    metadata = opts.metadata or {},
    command_args = command_args,
    on_complete = callback,
  })

  return job_id
end

-- ============================================================================
-- JOB QUEUE SYSTEM
-- ============================================================================

JobQueue = {
  jobs = {},
  order = {},
  next_id = 1,
  last_job_id = nil,
  stats = { created = 0, completed = 0, failed = 0, cancelled = 0 },
  active_subprocesses = {},
  running_job_id = nil,
  max_history = 200,
}

function JobQueue:prune_history()
  local i = 1
  while #self.order > self.max_history and i <= #self.order do
    local old_id = self.order[i]
    local old_job = self.jobs[old_id]
    if old_job and old_job.state ~= "running" and old_job.state ~= "pending" then
      table.remove(self.order, i)
      self.jobs[old_id] = nil
      self.active_subprocesses[old_id] = nil
    else
      i = i + 1
    end
  end
end

function JobQueue:run_next_job()
  if self.running_job_id ~= nil then
    return
  end
  for _, id in ipairs(self.order) do
    local job = self.jobs[id]
    if job and job.state == "pending" then
      self:execute_job(id)
      return
    end
  end
  State.processing = false
  State.current_job_id = nil
  State.progress = 0
end

function JobQueue:add_job(job)
  local id = self.next_id
  self.next_id = self.next_id + 1
  job.id = id
  job.state = "pending"
  job.progress = 0
  job.created_at = os.time()
  self.jobs[id] = job
  table.insert(self.order, id)
  self.last_job_id = id
  State.last_job_id = id
  self.stats.created = self.stats.created + 1
  self:prune_history()
  self:run_next_job()
  return id
end

function JobQueue:execute_job(job_id)
  local job = self.jobs[job_id]
  if not job or job.state ~= "pending" then
    return
  end

  job.state = "running"
  self.running_job_id = job_id
  State.processing = true
  State.current_job_id = job_id
  State.progress = 0

  local args = {
    name = "subprocess",
    args = job.command_args,
    playback_only = false,
    capture_stdout = true,
    capture_stderr = true,
  }

  local handle = mp.command_native_async(args, function(success, result, error)
    self.active_subprocesses[job_id] = nil
    if self.running_job_id == job_id then
      self.running_job_id = nil
    end

    local was_cancelled = job.cancel_requested == true or job.state == "cancelled"
    local actual_success = success and result and result.status == 0 and not was_cancelled

    if was_cancelled then
      job.state = "cancelled"
      State.progress = 0
    else
      job.state = actual_success and "completed" or "failed"
      State.progress = actual_success and 100 or 0
    end

    job.result = result
    job.error = error
    job.completed_at = os.time()

    local is_intermediate = job.is_intermediate == true
    local is_merge = job.operation == "merge"
    local op_label = is_merge and "Merge" or "Cut"

    if actual_success then
      self.stats.completed = self.stats.completed + 1
      if not is_intermediate then
        if job.output_path then
          LastOutputPath = job.output_path
          if o.output.auto_open then
            open_output_folder(job.output_path)
          end
        end
        send_notification("Video Cutter", op_label .. " completed successfully!")
      end
    elseif not was_cancelled then
      self.stats.failed = self.stats.failed + 1
      local stderr_msg = result and result.stderr or ""
      local stdout_msg = result and result.stdout or ""
      local detail = stderr_msg ~= "" and stderr_msg or stdout_msg
      detail = detail:gsub("%s+$", "")
      send_notification("Video Cutter", op_label .. " failed. Check mpv console for details.")
      if detail ~= "" then
        Logger.error(
          "Job " .. job_id .. " failed (exit code: " .. (result and result.status or "unknown") .. "): " .. detail
        )
      else
        Logger.error(
          "Job "
            .. job_id
            .. " failed: "
            .. tostring(error)
            .. " (exit code: "
            .. (result and result.status or "unknown")
            .. ")"
        )
      end
    end

    if job.on_complete then
      job.on_complete(job_id, { success = actual_success, cancelled = was_cancelled, result = result, error = error })
    end

    if was_cancelled then
      osd("Job cancelled", 2)
    elseif not is_intermediate then
      if actual_success then
        if not is_merge then
          osd("Cut complete!", 3)
        end
      else
        local stderr_msg = result and result.stderr or ""
        local stdout_msg = result and result.stdout or ""
        local detail = stderr_msg ~= "" and stderr_msg or stdout_msg
        detail = detail:gsub("%s+$", "")

        local error_lines = {}
        for line in detail:gmatch("[^\r\n]+") do
          local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
          if
            trimmed:match("[Ee]rror")
            or trimmed:match("[Ff]ailed")
            or trimmed:match("[Ee]xception")
            or #error_lines == 0
          then
            table.insert(error_lines, trimmed)
          end
          if #error_lines >= 3 then
            break
          end
        end

        if #error_lines > 0 then
          local brief = table.concat(error_lines, " | "):sub(1, 120)
          osd(op_label .. " failed: " .. brief, 4)
        elseif detail ~= "" then
          osd(op_label .. " failed: " .. detail:sub(1, 120), 4)
        else
          osd(op_label .. " failed: " .. tostring(error), 3)
        end
      end
    end

    self:run_next_job()
  end)

  self.active_subprocesses[job_id] = true

  if handle then
    self.active_subprocesses[job_id] = handle
  else
    self.active_subprocesses[job_id] = nil
    self.running_job_id = nil
    job.state = "failed"
    job.completed_at = os.time()
    self.stats.failed = self.stats.failed + 1
    State.progress = 0
    Logger.error("Job " .. job_id .. " failed to start")
    -- Fire the completion callback so job-specific cleanup (e.g. removing the
    -- remote-cut .source.mkv temp) still runs even though the process never
    -- spawned; otherwise the temp file leaks forever.
    if job.on_complete then
      job.on_complete(job_id, { success = false, cancelled = false, result = nil, error = "failed to start" })
    end
    self:run_next_job()
  end
end

-- Remove every on-disk artifact a job may have started: the final output
-- (possibly a partial), its yt-dlp-style ".part" sibling, and the
-- remote-cut temp (outpath .. ".source.mkv") recorded in metadata.
local function remove_job_outputs(job)
  local paths = {}
  local function add(p)
    if p and utils.file_info(p) then
      paths[#paths + 1] = p
    end
  end
  add(job.output_path)
  add(job.output_path and job.output_path .. ".part")
  local temp_path = job.metadata and job.metadata.temp_path
  add(temp_path)
  add(temp_path and temp_path .. ".part")
  for _, p in ipairs(paths) do
    os.remove(p)
  end
end
function JobQueue:cancel(job_id)
  local job = self.jobs[job_id]
  if not job then
    return false, "Job not found"
  end
  if job.state == "completed" or job.state == "failed" or job.state == "cancelled" then
    return false, "Job is already " .. job.state
  end

  local was_pending = job.state == "pending"
  job.cancel_requested = true
  job.state = "cancelled"
  job.completed_at = os.time()
  self.stats.cancelled = self.stats.cancelled + 1

  if was_pending then
    self:run_next_job()
    return true
  end

  local handle = self.active_subprocesses[job_id]
  if handle ~= nil and type(handle) ~= "boolean" then
    mp.abort_async_command(handle)
  end
  -- Remove the partial output the aborted subprocess may have started
  -- writing; a leftover corrupt file would otherwise be skipped forever by
  -- the $n auto-increment collision loop.
  remove_job_outputs(job)
  -- Clear immediately regardless of the abort callback contract: mpv's
  -- abort_async_command does not guarantee a follow-up callback in all
  -- versions, so relying on the async completion to clear running_job_id
  -- and advance the queue can stall it. The (late) callback still runs and
  -- sees job.state == "cancelled", so it no-ops the success/complete path.
  if self.running_job_id == job_id then
    self.running_job_id = nil
    self.active_subprocesses[job_id] = nil
    self:run_next_job()
  end

  return true
end

function JobQueue:get_latest_running_media_job()
  for i = #self.order, 1, -1 do
    local job = self.jobs[self.order[i]]
    if job and job.state == "running" then
      return job
    end
  end
  return nil
end

function JobQueue:get_stats()
  local stats = { pending = 0, running = 0, completed = 0, failed = 0, cancelled = 0 }
  for _, job in pairs(self.jobs) do
    if stats[job.state] then
      stats[job.state] = stats[job.state] + 1
    end
  end
  return stats
end

-- ============================================================================
-- VALIDATION AND HELPER FUNCTIONS
-- ============================================================================

local function validate_duration(shift, endpos)
  if shift < 0 then
    osd("Warning: Start time is negative, clamping to 0", 3)
    shift = 0
  end

  local video_duration = get_property_number("duration")
  if video_duration and video_duration > 0 then
    if endpos > video_duration then
      osd("Warning: End time exceeds video duration, will cut to end", 3)
      endpos = video_duration
    end
  end

  local duration = endpos - shift
  if duration <= 0 then
    osd("Invalid duration: End time must be after start time", 3)
    return false
  end
  if duration < 0.1 then
    osd("Invalid duration: Segment too short (minimum 0.1s)", 3)
    return false
  end
  if duration > 86400 then
    osd("Warning: Very long segment (>24h)", 3)
  end

  return true, shift, endpos
end

local function check_processing()
  if State.processing then
    local job = JobQueue and JobQueue:get_latest_running_media_job() or nil
    local op = (job and job.operation) and (" [" .. tostring(job.operation) .. "]") or ""
    osd(
      "Processing in progress" .. op .. " (press " .. key_value("key_cancel_job", "x") .. " to cancel)",
      2
    )
    return true
  end
  return false
end

-- ============================================================================
-- UNDO SYSTEM
-- ============================================================================

local function push_undo(action)
  table.insert(UndoStack, action)
  if #UndoStack > 50 then
    table.remove(UndoStack, 1)
  end
end

local function undo_last()
  if #UndoStack == 0 then
    osd("Nothing to undo", 2)
    return
  end
  local action = table.remove(UndoStack)
  if action.type == "clear_mark" then
    o.encoding.cut_pos = action.cut_pos
    osd("Undo: Restored mark at " .. format_timestamp(action.cut_pos), 2)
  elseif action.type == "set_mark" then
    o.encoding.cut_pos = nil
    osd("Undo: Cleared mark", 2)
  elseif action.type == "set_pending_start" then
    PendingSegmentStart = nil
    osd("Undo: Cleared pending start", 2)
  elseif action.type == "clear_pending_start" then
    PendingSegmentStart = action.pos
    osd("Undo: Restored pending start at " .. format_timestamp(action.pos), 2)
  elseif action.type == "add_segment" then
    if #Segments > 0 then
      table.remove(Segments)
      save_queue()
      osd("Undo: Removed last segment", 2)
    end
  end
  mp.set_property("ab-loop-a", "")
  mp.set_property("ab-loop-b", "")
end

-- ============================================================================
-- OUTPUT NAMING TEMPLATES
-- ============================================================================

local function format_output_name(template, vars)
  local token_map = {
    f = vars.filename or "clip",
    t = sanitize_filename(vars.media_title or vars.filename or "clip"),
    s = (vars.start_time or "00_00_00"):gsub(":", "_"),
    e = (vars.end_time or "00_00_00"):gsub(":", "_"),
    d = (vars.duration or "00_00_00"):gsub(":", "_"),
    x = vars.extension or "mp4",
    p = CurrentPreset or "default",
    D = os.date("%Y%m%d"),
    T = os.date("%H%M%S"),
    r = string.format("%04d", math.random(1, 9999)),
  }

  local result = template:gsub("%$([%a%d])", function(c)
    if c == "n" then
      return "$n"
    end
    return token_map[c] or ("$" .. c)
  end)

  if result:find("%$n") then
    if o.flags.overwrite then
      return sanitize_filename(result:gsub("%$n", "1"))
    end
    for n = 1, 9999 do
      local candidate = sanitize_filename(result:gsub("%$n", tostring(n)))
      local test_path = utils.join_path(o.target_dir, candidate)
      if not utils.file_info(test_path) then
        return candidate
      end
    end
    Logger.warn("Filename collision limit reached (9999), using random suffix")
    return sanitize_filename(result:gsub("%$n", tostring(math.random(10000, 99999))))
  end
  return sanitize_filename(result)
end

local function get_outname(shift, endpos)
  local basename = get_stream_type() ~= "local_file" and (get_property("media-title") or "clip")
    or get_property("filename/no-ext")
    or "clip"
  local start_time = format_timestamp(shift, false)
  local end_time = format_timestamp(endpos, false)
  local extension = should_make_gif() and "gif" or o.encoding.format
  if should_make_audio_only() then
    if o.encoding.audio.codec == "opus" then
      extension = "opus"
    elseif o.encoding.audio.codec == "mp3" then
      extension = "mp3"
    elseif o.encoding.audio.codec == "flac" then
      extension = "flac"
    elseif o.encoding.audio.codec == "copy" then
      extension = (o.encoding.format == "webm") and "opus" or "m4a"
    else
      extension = "m4a"
    end
  end
  local vars = {
    filename = basename,
    media_title = get_property("media-title"),
    start_time = start_time,
    end_time = end_time,
    duration = format_timestamp(endpos - shift, false),
    extension = extension,
  }
  local template = o.output.template or "$f_$s_$e.$x"
  if o.naming and o.naming.auto_increment and not template:find("%$n") then
    if template:match("%.%$x$") then
      template = template:gsub("%.%$x$", "_$n.$x")
    else
      template = template .. "_$n"
    end
  end
  local filename = format_output_name(template, vars)
  return utils.join_path(o.target_dir, filename)
end

-- ============================================================================
-- PATH NORMALIZATION AND ESCAPING
-- ============================================================================

local function normalize_path(path)
  if not path then
    return nil
  end
  local ok, result = pcall(function()
    return mp.command_native({ "normalize-path", path })
  end)
  if ok and result then
    return result
  end
  path = path:gsub("\\", "/")
  if is_windows then
    path = path:gsub("^(%a):/", function(d)
      return d:upper() .. ":/"
    end)
  end
  return path
end

local function escape_ffmpeg_filter_path(path)
  if not path then
    return nil
  end

  path = normalize_path(path)
  if not path then
    return nil
  end

  local escaped = path:gsub("\\", "/")
  escaped = escaped:gsub("'", "'\\''")
  return "'" .. escaped .. "'"
end

local function check_keyframe_proximity(shift, endpos)
  local video_duration = get_property_number("duration")
  if not video_duration or video_duration <= 0 then
    return false
  end
  local segment_duration = endpos - shift
  if segment_duration < 1.0 then
    local warning = string.format(
      "Segment is %.2fs - may start/end mid-keyframe. Consider a longer segment for cleaner cuts.",
      segment_duration
    )
    Logger.warn(warning)
    osd(warning, 3)
    return true
  end
  return false
end

-- ============================================================================
-- SUBTITLE FILTER
-- ============================================================================

local function is_image_sub_codec(codec)
  return codec == "hdmv_pgs_subtitle" or codec == "dvd_subtitle" or codec == "dvb_subtitle" or codec == "xsub"
end

local function is_ass_sub_codec(codec)
  return codec == "ass" or codec == "ssa"
end

local function build_gif_filter(fps, scale)
  return string.format(
    "fps=%d,scale=%d:-1:flags=lanczos,split[s0][s1];"
      .. "[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer",
    fps,
    scale
  )
end

local function get_selected_sub_track(sid)
  if not sid or sid <= 0 then
    return nil, 0
  end
  local tracks = mp.get_property_native("track-list") or {}
  for _, track in ipairs(tracks) do
    if track.type == "sub" and track.id == sid then
      local sub_stream_idx = (track.id or sid) - 1
      if sub_stream_idx < 0 then
        sub_stream_idx = 0
      end
      return track, sub_stream_idx
    end
  end
  return nil, 0
end

-- Returns filter_string, sub_delay
local function get_subtitle_filter(shift, video_file_path)
  video_file_path = video_file_path or get_property("path")
  local sid = tonumber(mp.get_property("sid"))
  if not o.encoding.subtitles.enabled or not sid or sid <= 0 then
    return nil, 0
  end

  local selected_track, sub_stream_index = get_selected_sub_track(sid)
  if not selected_track then
    return nil, 0
  end

  local codec = selected_track["codec"] or ""
  if is_image_sub_codec(codec) then
    Logger.warn(string.format("Subtitle burn-in skipped: image-based format '%s' is not supported", codec))
    return nil, 0
  end

  local is_ass = is_ass_sub_codec(codec)
  local style_option = ""
  if not is_ass then
    style_option = ":force_style='Fontname=Sans,FontSize=24'"
  end

  local sub_delay = tonumber(mp.get_property("sub-delay")) or 0

  local sub_file = selected_track["external-filename"]
  if sub_file then
    if not utils.file_info(sub_file) then
      Logger.warn("External subtitle file not found: " .. sub_file)
      return nil, sub_delay
    end
    local escaped_path = escape_ffmpeg_filter_path(sub_file)
    if not escaped_path then
      Logger.warn("Failed to normalize external subtitle path: " .. sub_file)
      return nil, sub_delay
    end
    Logger.info("Burning external subtitles: " .. sub_file)
    return string.format("subtitles=%s%s", escaped_path, style_option), sub_delay
  else
    if not video_file_path or video_file_path:match("://") then
      return nil, sub_delay
    end

    local escaped_video = escape_ffmpeg_filter_path(video_file_path)
    if not escaped_video then
      Logger.warn("Failed to normalize video path for subtitle burn-in: " .. video_file_path)
      return nil, sub_delay
    end

    Logger.info(string.format("Burning embedded subtitles (stream %d) from: %s", sub_stream_index, video_file_path))
    return string.format("subtitles=%s:si=%d%s", escaped_video, sub_stream_index, style_option), sub_delay
  end
end

-- ============================================================================
-- MPV FILTER EXPORT
-- ============================================================================

local function get_video_filters_from_mpv()
  local filters = {}
  local vf_table = mp.get_property_native("vf")

  for _, vf in ipairs(vf_table or {}) do
    local name = vf["name"]
    local params = vf["params"] or {}

    if name == "crop" then
      local w = params["w"]
      local h = params["h"]
      local x = params["x"] or 0
      local y = params["y"] or 0
      if w and h then
        table.insert(filters, string.format("crop=%s:%s:%s:%s", w, h, x, y))
      end
    elseif name == "rotate" then
      local angle = params["angle"]
      if angle and angle ~= 0 then
        if angle == 90 then
          table.insert(filters, "transpose=1")
        elseif angle == 180 then
          -- 180° = two 90° CW; transpose=2 is 90° CCW, not 180°
          table.insert(filters, "transpose=1")
          table.insert(filters, "transpose=1")
        elseif angle == 270 then
          -- 270° CW == 90° CCW; transpose=3 is 90° CW+vflip, not 270° CW
          table.insert(filters, "transpose=2")
        end
      end
    elseif name == "flip" then
      table.insert(filters, "vflip")
    elseif name == "mirror" then
      table.insert(filters, "hflip")
    elseif name == "scale" then
      local w = params["w"]
      local h = params["h"]
      if w and h then
        table.insert(filters, string.format("scale=%s:%s", w, h))
      end
    end
  end

  return filters
end

-- ============================================================================
-- SEGMENT QUEUE PERSISTENCE
-- ============================================================================

local function get_queue_file_path()
  local source = get_property("path") or "default"
  local hash = 0
  for i = 1, #source do
    hash = ((hash * 31) + string.byte(source, i)) % 4294967296
  end
  local safe_name = string.format("queue_%08x.json", hash)
  return mp.command_native({ "expand-path", "~~/" .. safe_name })
end

save_queue = function()
  local qfile = get_queue_file_path()
  local file, err = io.open(qfile, "w")
  if file then
    local ok, write_err = file:write(utils.format_json({
      segments = Segments,
      source_file = get_property("path"),
      saved_at = os.time(),
    }))
    if not ok then
      Logger.error("Failed to write queue: " .. tostring(write_err))
    end
    file:close()
  else
    Logger.error("Failed to save queue file: " .. tostring(err))
  end
end

load_queue = function()
  local qfile = get_queue_file_path()
  local file, err = io.open(qfile, "r")
  if file then
    local content = file:read("*all")
    file:close()
    local ok, data = pcall(utils.parse_json, content)
    if ok and type(data) == "table" and data.segments then
      Segments = data.segments
      return #data.segments
    elseif not ok then
      Logger.error("Failed to parse queue file: " .. tostring(data))
    end
  end
  return 0
end

-- ============================================================================
-- YTDLP COMMAND BUILDER
-- ============================================================================

local function build_ytdlp_command(inpath, duration_str, output_path, extra_args)
  local stream_type = get_stream_type(inpath or get_property("path"))

  local cmd = Command
    :new("yt-dlp")
    :arg("--ignore-config")
    :arg("--no-playlist")
    :arg("--no-write-thumbnail")
    :arg("--no-write-info-json")
    :arg("--no-clean-infojson")
    :arg("--no-write-description")
    :arg("--no-write-comments")
    :arg("--no-write-playlist-metafiles")
    :arg("-S", "proto:https")
    :arg("--concurrent-fragments", "1")
    :arg("--retries", "10")
    :arg("--fragment-retries", "10")
    :arg("--merge-output-format", "mkv") -- Always merge to mkv for the temp file to avoid mp4 remux issues
  -- Fetch subtitles so they can be embedded/burned in the ffmpeg step.
  -- Gate on subtitles.enabled: otherwise we waste bandwidth and disk on
  -- temp sub files that the re-encode step ignores, and may fail on sources
  -- that 403 on sub requests.
  if o.encoding.subtitles.enabled then
    cmd:arg("--write-subs")
    cmd:arg("--write-auto-subs")
    cmd:arg("--embed-subs")
  end

  if duration_str then
    cmd:arg("--download-sections", duration_str)
    -- Do not pass --force-keyframes-at-cuts to prevent yt-dlp internal ffmpeg from re-encoding
  end

  if extra_args then
    for _, arg in ipairs(extra_args) do
      cmd:arg(arg)
    end
  end

  local ua = mp.get_property("user-agent")
  local referrer = mp.get_property("referrer")
  if ua and ua ~= "" and ua ~= "libmpv" then
    cmd:arg("--user-agent", ua)
  end
  if referrer and referrer ~= "" then
    cmd:arg("--referer", referrer)
  end

  if stream_type ~= "twitch" and stream_type ~= "kick" then
    local max_quality = tonumber(o.youtube.max_quality) or 1080
    -- Prefer mp4/m4a to ensure native mp4 container compatibility
    local format_selector = string.format(
      "bestvideo[ext=mp4][height<=?%d]+bestaudio[ext=m4a]/best[ext=mp4][height<=?%d]/best",
      max_quality,
      max_quality
    )
    cmd:arg("-f", format_selector)
  end

  for _, arg in ipairs(o.youtube.dlp_args or {}) do
    cmd:arg(arg)
  end

  cmd:arg("--output", output_path):arg(inpath)

  return cmd
end

-- ============================================================================
-- FFMPEG COMMAND BUILDING
-- ============================================================================

-- Add encoder-specific quality args for the active (possibly HW) video codec.
-- Returns false for software encoders so call sites can apply their own
-- -pix_fmt (local build uses a format=yuv420p filter, remote adds it directly).
-- Bitrate (ABR) and CRF are mutually exclusive rate-control modes: passing
-- both makes ffmpeg silently honor -b:v and drop CRF. Gate on bitrate:
-- empty bitrate = CRF mode (default), non-empty = ABR.
local function add_encode_quality_args(cmd, vcodec)
  local use_bitrate = o.encoding.video.bitrate ~= nil and o.encoding.video.bitrate ~= ""
  local crf = tostring(o.encoding.video.crf or 23)
  if vcodec:match("nvenc") then
    cmd:arg("-preset", o.encoding.hardware.quality_preset or "fast")
    if not use_bitrate then
      cmd:arg("-rc", "vbr")
      cmd:arg("-cq", crf)
    end
    cmd:arg("-pix_fmt", "nv12")
  elseif vcodec:match("qsv") then
    if not use_bitrate then
      cmd:arg("-global_quality", crf)
    end
  elseif vcodec:match("vaapi") then
    if not use_bitrate then
      cmd:arg("-qp", crf)
    end
  elseif vcodec:match("videotoolbox") then
    if not use_bitrate then
      cmd:arg("-q:v", crf)
    end
  elseif vcodec:match("amf") then
    if not use_bitrate then
      cmd:arg("-qp_i", crf)
      cmd:arg("-qp_p", crf)
    end
  else
    cmd:arg("-preset", o.encoding.video.preset or "medium")
    if not use_bitrate then
      cmd:arg("-crf", crf)
    end
    return false
  end
  return true
end

local function build_ffmpeg_command(shift, endpos, outpath)
  local duration = endpos - shift
  local cmd = Command:new(o.paths.ffmpeg_path)

  local input_path = get_property("path")
  if not input_path or input_path == "" then
    return nil, "No input file"
  end
  if input_path:match("^ytdl://") then
    input_path = input_path:gsub("^ytdl://", "")
  end

  cmd:arg("-v", "warning")
  cmd:arg("-stats", "-hide_banner")
  cmd:arg(o.flags.overwrite and "-y" or "-n")

  local is_remote_input = input_path:match("://") ~= nil
  if is_remote_input then
    local ua = mp.get_property("user-agent")
    local referrer = mp.get_property("referrer")
    if ua and ua ~= "" and ua ~= "libmpv" then
      cmd:arg("-user_agent", ua)
    end
    if referrer and referrer ~= "" then
      cmd:arg("-referer", referrer)
    end
  end

  local subtitle_filter, sub_delay = get_subtitle_filter(shift, input_path)
  local subtitle_filter_available = o.encoding.subtitles.enabled and subtitle_filter or nil
  local active_sub_filter = (not o.encoding.lossless) and subtitle_filter_available or nil

  if o.encoding.hardware.enabled and HardwareAccelDetected and HardwareAccelDetected ~= "software" then
    if o.encoding.hardware.decoder ~= "auto" then
      cmd:arg("-hwaccel", o.encoding.hardware.decoder)
    end
    if o.encoding.hardware.device ~= "" then
      cmd:arg("-hwaccel_device", o.encoding.hardware.device)
    end
  end

  cmd:arg("-ss", tostring(shift))
  cmd:arg("-i", input_path)

  cmd:arg("-t", tostring(duration))
  cmd:arg("-reset_timestamps", "1")
  cmd:arg("-fflags", "+genpts")
  cmd:arg("-avoid_negative_ts", "make_zero")

  if should_make_gif() then
    cmd:arg("-vf", build_gif_filter(o.encoding.gif.fps, o.encoding.gif.scale))
    cmd:arg("-loop", "0")
    cmd:arg("-an")
  elseif should_make_audio_only() then
    local aid = get_property_number("aid")
    if aid and aid > 0 then
      cmd:arg("-map", string.format("0:a:%d?", aid - 1))
    end
    cmd:arg("-c:a", o.encoding.audio.codec)
    if o.encoding.audio.codec ~= "copy" then
      if o.encoding.audio.bitrate and o.encoding.audio.bitrate ~= "" then
        cmd:arg("-b:a", o.encoding.audio.bitrate)
      end
      cmd:arg("-ac", "2")
    end
    cmd:arg("-vn")
  elseif o.encoding.lossless or o.encoding.video.codec == "copy" then
    if o.encoding.apply_filters and #get_video_filters_from_mpv() > 0 then
      Logger.warn("Lossless mode: MPV video filters will be ignored (stream copy enabled)")
    end
    if subtitle_filter_available then
      Logger.warn("Lossless mode: Subtitle burn-in will not work (stream copy enabled)")
    end

    local vid = get_property_number("vid")
    if vid and vid > 0 then
      cmd:arg("-map", string.format("0:v:%d?", vid - 1))
    end
    cmd:arg("-c:v", "copy")

    if o.encoding.audio.enabled then
      local aid = get_property_number("aid")
      if aid and aid > 0 then
        cmd:arg("-map", string.format("0:a:%d?", aid - 1))
      end
      cmd:arg("-c:a", "copy")
    else
      cmd:arg("-an")
    end

    if o.encoding.subtitles.enabled then
      local sid = get_property_number("sid")
      local selected_sub_track, sub_stream_idx = get_selected_sub_track(sid)
      if selected_sub_track then
        local codec = selected_sub_track["codec"] or ""
        if is_image_sub_codec(codec) then
          Logger.warn("Lossless mode: Skipping image subtitles (cannot copy to MP4 easily without conversion)")
        elseif is_ass_sub_codec(codec) and o.encoding.format == "mp4" then
          Logger.warn("Lossless mode: MP4 does not support ASS subtitle copy, skipping subtitles")
          osd("Lossless+MP4: ASS subtitles skipped (not supported in MP4)", 3)
        else
          if o.encoding.format == "mp4" then
            cmd:arg("-map", string.format("0:s:%d?", sub_stream_idx))
            cmd:arg("-c:s", "mov_text")
          else
            cmd:arg("-map", string.format("0:s:%d?", sub_stream_idx))
            cmd:arg("-c:s", "copy")
          end
        end
      end
    end
  else
    -- Re-encode mode for maximum compatibility
    local vid = get_property_number("vid")
    local aid = get_property_number("aid")
    local vcodec = o.encoding.video.codec

    local hw_enc = hardware_encoder_for(o.encoding.video.codec)
    if o.encoding.hardware.enabled and hw_enc then
      vcodec = hw_enc
    end

    if vid and vid > 0 then
      cmd:arg("-map", string.format("0:v:%d?", vid - 1))
      cmd:arg("-c:v", vcodec)
    end

    add_encode_quality_args(cmd, vcodec)

    if o.encoding.video.bitrate and o.encoding.video.bitrate ~= "" then
      cmd:arg("-b:v", o.encoding.video.bitrate)
    end

    if o.encoding.video.fps and o.encoding.video.fps ~= "" then
      cmd:arg("-r", o.encoding.video.fps)
    end

    local video_filters = {}

    -- Apply mpv filters FIRST so subtitles are rendered on the uncropped frame
    if o.encoding.apply_filters then
      local mpv_filters = get_video_filters_from_mpv()
      for _, filter in ipairs(mpv_filters) do
        table.insert(video_filters, filter)
      end
    end

    if active_sub_filter then
      -- Shift video PTS to match the absolute timestamps expected by the subtitle file
      -- We must account for both the cut start (shift) and the user's sub-delay
      table.insert(video_filters, string.format("setpts=PTS+%.3f/TB", shift - sub_delay))
      table.insert(video_filters, active_sub_filter)
      table.insert(video_filters, "setpts=PTS-STARTPTS")
    end

    -- Enforce yuv420p for maximum compatibility on all platforms
    table.insert(video_filters, "format=yuv420p")

    if #video_filters > 0 then
      local vf_chain = table.concat(video_filters, ",")
      if o.flags.debug then
        Logger.info("Video filter chain: " .. vf_chain)
      end
      cmd:arg("-vf", vf_chain)
    end

    if o.encoding.audio.enabled and aid and aid > 0 then
      cmd:arg("-map", string.format("0:a:%d?", aid - 1))
      cmd:arg("-c:a", o.encoding.audio.codec)
      cmd:arg("-b:a", o.encoding.audio.bitrate)
      cmd:arg("-ac", "2")
    else
      cmd:arg("-an")
    end

    local sid = get_property_number("sid")
    if o.encoding.subtitles.enabled and sid and sid > 0 and not active_sub_filter then
      local selected_sub_track, sub_stream_idx = get_selected_sub_track(sid)
      if selected_sub_track then
        local codec = selected_sub_track["codec"] or ""
        -- Skip muxing image-based subs to MP4 as it's unsupported by mov_text
        if is_image_sub_codec(codec) then
          Logger.warn("Skipping muxing image-based subtitles to MP4 (unsupported)")
        else
          if o.encoding.format == "mp4" then
            cmd:arg("-map", string.format("0:s:%d?", sub_stream_idx))
            cmd:arg("-c:s", "mov_text")
          elseif o.encoding.format == "webm" then
            if codec == "webvtt" then
              cmd:arg("-map", string.format("0:s:%d?", sub_stream_idx))
              cmd:arg("-c:s", "copy")
            end
          else
            cmd:arg("-map", string.format("0:s:%d?", sub_stream_idx))
            cmd:arg("-c:s", "copy")
          end
        end
      end
    end
  end

  if o.encoding.custom_ffmpeg_args and #o.encoding.custom_ffmpeg_args > 0 then
    for _, arg in ipairs(o.encoding.custom_ffmpeg_args) do
      cmd:arg(arg)
    end
  end

  if o.encoding.format == "mp4" and not should_make_gif() and not should_make_audio_only() then
    cmd:arg("-movflags", "+faststart")
  end

  cmd:arg(outpath)

  return cmd
end

-- ============================================================================
-- REMOTE STREAM PROCESSING (yt-dlp)
-- ============================================================================

local function cleanup_ytdlp_numbered_files(target_path)
  local dir, filename = utils.split_path(target_path)
  local ext = filename:match("(%.[^%.]+)$") or ""
  local base = ext ~= "" and filename:sub(1, #filename - #ext) or filename

  local files = utils.readdir(dir)
  if files then
    local pattern = "^" .. base:gsub("%W", "%%%0") .. "_(%d+)" .. ext:gsub("%W", "%%%0") .. "$"
    for _, f in ipairs(files) do
      if f:match(pattern) and utils.join_path(dir, f) ~= target_path then
        Logger.debug("Removing stray yt-dlp numbered file: " .. f)
        os.remove(utils.join_path(dir, f))
      end
    end
  end
end

local function get_remote_duration_str(stream_type, shift, endpos)
  if stream_type == "twitch" then
    local offset_s = tonumber(o.youtube.twitch_offset_start) or 63
    local offset_e = tonumber(o.youtube.twitch_offset_end) or 61
    local start_time = math.max(0, shift - offset_s)
    local end_time = math.max(0, endpos - offset_e)
    if start_time >= end_time then
      Logger.warn(string.format("Twitch offset makes segment invalid: %s >= %s", start_time, end_time))
      return nil
    end
    return string.format("*%s-%s", start_time, end_time)
  elseif stream_type == "kick" then
    local offset_s = tonumber(o.youtube.kick_offset_start) or 0
    local offset_e = tonumber(o.youtube.kick_offset_end) or 0
    local start_time = math.max(0, shift - offset_s)
    local end_time = math.max(0, endpos - offset_e)
    if start_time >= end_time then
      Logger.warn(string.format("Kick offset makes segment invalid: %s >= %s", start_time, end_time))
      return nil
    end
    return string.format("*%s-%s", start_time, end_time)
  end
  return string.format("*%s-%s", shift, endpos)
end

-- Two-step process: 1. yt-dlp downloads roughly to temp.mkv, 2. ffmpeg encodes precisely to final output
process_remote_segment = function(shift, endpos, outpath, inpath, callback, is_intermediate)
  local stream_type = get_stream_type(inpath)
  local duration_str = get_remote_duration_str(stream_type, shift, endpos)

  if not duration_str then
    osd("Offset makes segment invalid, skipping", 3)
    if callback then
      callback(false)
    end
    return
  end

  local temp_path = outpath .. ".source.mkv"

  local function encode_temp_to_output()
    local ffmpeg_cmd = Command:new(o.paths.ffmpeg_path)
    ffmpeg_cmd:arg("-v", "warning")
    ffmpeg_cmd:arg("-stats", "-hide_banner")
    ffmpeg_cmd:arg("-y")
    ffmpeg_cmd:arg("-i", temp_path)

    if o.encoding.lossless or o.encoding.video.codec == "copy" then
      ffmpeg_cmd:arg("-c", "copy")
    elseif should_make_gif() then
      ffmpeg_cmd:arg("-vf", build_gif_filter(o.encoding.gif.fps, o.encoding.gif.scale))
      ffmpeg_cmd:arg("-loop", "0")
      ffmpeg_cmd:arg("-an")
    elseif should_make_audio_only() then
      ffmpeg_cmd:arg("-vn")
      ffmpeg_cmd:arg("-c:a", o.encoding.audio.codec)
      ffmpeg_cmd:arg("-b:a", o.encoding.audio.bitrate or "192k")
      ffmpeg_cmd:arg("-ac", "2")

    -- Audio-only ignores subtitles; yt-dlp sub flags are gated upstream
    -- so any leftover sub streams are not muxed into an audio file.
    else
      -- Re-encode, honoring selected video/audio codecs
      local vcodec = o.encoding.video.codec
      local hw_enc = hardware_encoder_for(o.encoding.video.codec)
      if hw_enc then
        vcodec = hw_enc
      end
      ffmpeg_cmd:arg("-c:v", vcodec)
      -- Software encoders get yuv420p for max compatibility; HW encoders
      -- already set their own -pix_fmt inside the helper (nv12 for nvenc, etc.).
      if not add_encode_quality_args(ffmpeg_cmd, vcodec) then
        ffmpeg_cmd:arg("-pix_fmt", "yuv420p")
      end
      if o.encoding.video.bitrate and o.encoding.video.bitrate ~= "" then
        ffmpeg_cmd:arg("-b:v", o.encoding.video.bitrate)
      end
      if o.encoding.video.fps and o.encoding.video.fps ~= "" then
        ffmpeg_cmd:arg("-r", o.encoding.video.fps)
      end
      if o.encoding.audio.enabled then
        ffmpeg_cmd:arg("-c:a", o.encoding.audio.codec)
        ffmpeg_cmd:arg("-b:a", o.encoding.audio.bitrate or "192k")
        ffmpeg_cmd:arg("-ac", "2")
      else
        ffmpeg_cmd:arg("-an")
      end

      -- Handle subtitles downloaded by yt-dlp
      if o.encoding.subtitles.enabled then
        ffmpeg_cmd:arg("-map", "0:s?")
        if o.encoding.format == "mp4" then
          ffmpeg_cmd:arg("-c:s", "mov_text")
        else
          ffmpeg_cmd:arg("-c:s", "copy")
        end
      end
    end

    if o.encoding.format == "mp4" and not should_make_gif() and not should_make_audio_only() then
      ffmpeg_cmd:arg("-movflags", "+faststart")
    end

    ffmpeg_cmd:arg(outpath)

    ffmpeg_cmd:run({
      job_type = "media",
      operation = "remote_encode",
      is_intermediate = is_intermediate or false,
      output_path = outpath,
      -- The yt-dlp temp this encode consumes; abort paths must remove it
      -- together with the partial final file or it leaks in the target dir.
      metadata = { temp_path = temp_path },
    }, function(job_id2, result2)
      if utils.file_info(temp_path) then
        os.remove(temp_path)
      end
      if result2.cancelled then
        if utils.file_info(outpath) then
          os.remove(outpath)
        end
        if callback then
          callback(false)
        end
        return
      end
      if result2.success and utils.file_info(outpath) then
        LastOutputPath = outpath
        Logger.info("Remote clip saved: " .. outpath)
        if callback then
          callback(true)
        end
      else
        Logger.error("Remote encode failed: " .. tostring(result2.error))
        if utils.file_info(outpath) then
          os.remove(outpath)
        end
        if callback then
          callback(false)
        end
      end
    end)
  end

  local clean_inpath = inpath
  if clean_inpath and clean_inpath:match("^ytdl://") then
    clean_inpath = clean_inpath:gsub("^ytdl://", "")
  end

  local cmd = build_ytdlp_command(clean_inpath, duration_str, temp_path)

  cmd:run({
    job_type = "media",
    operation = "remote_download",
    is_intermediate = true,
    output_path = temp_path,
    duration = endpos - shift,
  }, function(job_id, result)
    if result.cancelled then
      cleanup_ytdlp_numbered_files(temp_path)
      if utils.file_info(temp_path) then
        os.remove(temp_path)
      end
      if callback then
        callback(false)
      end
      return
    end
    if result.success then
      cleanup_ytdlp_numbered_files(temp_path)
      if utils.file_info(temp_path) then
        encode_temp_to_output()
      else
        Logger.warn("Remote clip completed but source file not found at: " .. temp_path)
        if callback then
          callback(false)
        end
      end
    else
      local stderr_msg = result.result and result.result.stderr or ""
      local stdout_msg = result.result and result.result.stdout or ""
      local details = stderr_msg ~= "" and stderr_msg or stdout_msg
      if details ~= "" then
        details = details:gsub("%s+$", "")
        Logger.error("yt-dlp failed: " .. details)
        if details:match("impersonate") or details:match("403 Forbidden") or details:match("PO Token") then
          osd("yt-dlp 403/PO Token Error: Try installing 'curl_cffi' (pip install curl_cffi) or updating yt-dlp.", 6)
        end
      else
        Logger.error("yt-dlp failed: " .. tostring(result.error))
      end
      cleanup_ytdlp_numbered_files(temp_path)
      if utils.file_info(temp_path) then
        os.remove(temp_path)
      end
      osd("yt-dlp failed (see log for details)", 3)
      if callback then
        callback(false)
      end
    end
  end)
end

local function process_remote(shift, endpos, outpath, inpath)
  if not o.flags.ytdlp_available then
    osd("yt-dlp not available. Install yt-dlp for remote stream cutting.", 3)
    return
  end

  local stream_type = get_stream_type(inpath)
  if stream_type == "local_file" then
    osd("Error: remote processing called on local file - use ffmpeg cut instead", 3)
    State.processing = false
    return
  end

  State.processing = true

  if inpath and inpath:match("^ytdl://") then
    inpath = inpath:gsub("^ytdl://", "")
  end

  process_remote_segment(shift, endpos, outpath, inpath, function(success)
    State.processing = false
    if success then
      osd("Cut complete!", 3)
    end
  end)
end

-- ============================================================================
-- CORE CUT FUNCTION
-- ============================================================================

cut_video = function(shift, endpos)
  if check_processing() then
    return
  end
  local ok, adjusted_shift, adjusted_endpos = validate_duration(shift, endpos)
  if not ok then
    return
  end
  shift, endpos = adjusted_shift, adjusted_endpos

  if o.flags.directory_ready == false then
    osd("Target directory is not available. Cannot process video.", 3)
    return
  end

  local inpath = get_property("path")
  if not inpath or inpath == "" then
    osd("No input file available", 3)
    return
  end

  local outpath = get_outname(shift, endpos)
  local stream_type = get_stream_type(inpath)
  local is_live = is_live_stream()
  local is_local_file = stream_type == "local_file" or utils.file_info(inpath) ~= nil

  if not o.flags.overwrite and not (o.naming and o.naming.auto_increment) and utils.file_info(outpath) then
    osd("Output file exists: " .. outpath, 3)
    return
  end

  if is_local_file then
    check_keyframe_proximity(shift, endpos)
  end

  if is_local_file or stream_type == "hls" then
    local cmd, err = build_ffmpeg_command(shift, endpos, outpath)
    if not cmd then
      osd("Error: " .. (err or "Failed to build command"), 3)
      return
    end

    local duration_str = format_duration(endpos - shift)
    local label = is_live and "LIVE" or (should_make_audio_only() and "Extract Audio" or "Cut")
    osd(string.format("%s: %s to %s (%s)", label, format_timestamp(shift), format_timestamp(endpos), duration_str), 3)

    cmd:run({
      job_type = "media",
      operation = should_make_audio_only() and "extract_audio" or "cut",
      output_path = outpath,
      duration = endpos - shift,
    }, function(job_id, result)
      if result.success then
        Logger.info("Cut completed: " .. outpath)
      else
        Logger.error("Cut failed: " .. tostring(result.error))
      end
    end)
    return true
  else
    if is_live then
      Logger.info("Live stream detected, using yt-dlp with section download")
    end
    process_remote(shift, endpos, outpath, inpath)
    return true
  end
end

local function execute_cut()
  if not o.encoding.cut_pos then
    osd("No mark set. Press 'c' to set mark first.", 3)
    return
  end
  local pos = get_property_number("time-pos")
  if not pos then
    return
  end

  local shift, endpos = math.min(o.encoding.cut_pos, pos), math.max(o.encoding.cut_pos, pos)
  if cut_video(shift, endpos) then
    o.encoding.cut_pos = nil
  end
end

local function quick_cut_last(seconds)
  if check_processing() then
    return
  end
  local pos = get_property_number("time-pos")
  if not pos or pos < seconds then
    osd("Stream position too early for " .. seconds .. "s clip", 2)
    return
  end

  local shift = pos - seconds
  local endpos = pos
  o.encoding.cut_pos = nil

  local stream_type = get_stream_type()
  local is_live = is_live_stream()
  local clip_label = is_live and "LIVE" or stream_type:upper()
  osd(string.format("Quick-cut: last %ds [%s]", seconds, clip_label), 2)

  cut_video(shift, endpos)
end

-- ============================================================================
-- TIMELINE OVERLAY
-- ============================================================================

local function init_timeline_overlay()
  TimelineOverlay.overlay_id = mp.create_osd_overlay("ass-events")
end

local function update_timeline_overlay()
  local overlay = TimelineOverlay.overlay_id
  if not overlay then
    return
  end

  local mark_pos = o.encoding.cut_pos
  local has_queue = o.flags.queue_mode and #Segments > 0
  if not TimelineOverlay.enabled and not mark_pos and not has_queue then
    if overlay.data ~= "" then
      overlay.data = ""
      overlay:update()
    end
    return
  end

  local duration = get_property_number("duration")
  if not duration or duration <= 0 then
    if overlay.data ~= "" then
      overlay.data = ""
      overlay:update()
    end
    return
  end

  local now = mp.get_property_number("time-pos") or 0
  local wall_time = mp.get_time()
  local segments_changed = (#Segments ~= TimelineOverlay.last_segment_count)
    or (o.flags.queue_mode ~= TimelineOverlay.last_queue_mode)
    or (mark_pos ~= TimelineOverlay.last_mark_pos)

  if not segments_changed and not TimelineOverlay._force_update then
    local elapsed = wall_time - TimelineOverlay.last_update_time
    if elapsed >= 0 and elapsed < TimelineOverlay.update_interval then
      return
    end
  end

  TimelineOverlay.last_update_time = wall_time
  TimelineOverlay.last_mark_pos = mark_pos
  TimelineOverlay.last_segment_count = #Segments
  TimelineOverlay.last_queue_mode = o.flags.queue_mode

  local osd_w, osd_h = OSD_CACHE.w, OSD_CACHE.h
  if osd_w == 0 or osd_h == 0 then
    return
  end

  local current_pos = now
  local ass = assdraw.ass_new()

  local bar_width = osd_w * 0.72
  local bar_height = math.max(14, math.floor(osd_h * 0.017))
  local bar_x = (osd_w - bar_width) / 2
  local bar_y = osd_h * 0.085
  local triangle_offset = math.max(22, math.floor(osd_h * 0.028))
  local fs_mark = math.max(26, math.floor(osd_h * 0.031))
  local fs_current = math.max(24, math.floor(osd_h * 0.028))
  local fs_total = math.max(20, math.floor(osd_h * 0.024))
  local fs_seg_label = math.max(16, math.floor(osd_h * 0.018))
  local marker_half = math.max(3, math.floor(bar_height * 0.32))
  local marker_pad = math.max(16, math.floor(bar_height * 2.4))
  local tri_w = math.max(8, math.floor(bar_height * 0.9))
  local tri_h = math.max(12, math.floor(bar_height * 1.15))
  local radius = math.max(5, math.floor(bar_height * 0.5))

  local progress_pct = math.min(math.max(current_pos / duration, 0), 1)
  local mark_pct = mark_pos and math.min(math.max(mark_pos / duration, 0), 1) or nil

  ass:new_event()
  ass:an(7)
  ass:pos(bar_x, bar_y)
  ass:append("{\\1c&H2A2A2A&\\bord0}")
  ass:draw_start()
  ass:round_rect_cw(0, 0, bar_width, bar_height, radius, radius)
  ass:draw_stop()

  if progress_pct > 0 then
    local fill_width = bar_width * progress_pct
    ass:new_event()
    ass:an(7)
    ass:pos(bar_x, bar_y)
    ass:append("{\\1c&H24B8FF&\\bord0}")
    ass:draw_start()
    ass:round_rect_cw(0, 0, fill_width, bar_height, radius, radius)
    ass:draw_stop()
  end

  if mark_pct then
    local mark_x = bar_x + (bar_width * mark_pct)

    ass:new_event()
    ass:an(7)
    ass:pos(mark_x, bar_y - math.floor(bar_height * 1.2))
    ass:append("{\\1c&H00FF00&\\bord0}")
    ass:draw_start()
    ass:rect_cw(-marker_half, 0, marker_half, bar_height + marker_pad)
    ass:draw_stop()

    ass:new_event()
    ass:an(7)
    ass:pos(mark_x, bar_y + bar_height + 6)
    ass:append("{\\1c&H00FF00&\\bord0}")
    ass:draw_start()
    ass:move_to(0, 0)
    ass:line_to(-tri_w, tri_h)
    ass:line_to(tri_w, tri_h)
    ass:line_to(0, 0)
    ass:draw_stop()

    ass:new_event()
    ass:an(5)
    ass:pos(mark_x, bar_y + bar_height + triangle_offset + fs_mark)
    ass:append(
      "{\\1c&H6DFF8F&\\3c&H000000&\\bord2\\shad1\\fs" .. fs_mark .. "\\b1}Mark: " .. format_timestamp(mark_pos, false)
    )
  end

  if o.flags.queue_mode and #Segments > 0 then
    local seg_base_color = o.flags.merge_mode and "&HDA70D6&" or "&HFFA500&"
    for idx, seg in ipairs(Segments) do
      local seg_start_pct = math.min(math.max(seg.start_pos / duration, 0), 1)
      local seg_end_pct_raw = seg.end_pos / duration
      local seg_clipped = seg_end_pct_raw > 1.0
      local seg_end_pct = math.min(seg_end_pct_raw, 1)
      local seg_x_start = bar_width * seg_start_pct
      local seg_x_end = bar_width * seg_end_pct

      local seg_color = seg_clipped and "&HFF6347&" or seg_base_color
      local seg_alpha = "&H90&"

      ass:new_event()
      ass:an(7)
      ass:pos(bar_x, bar_y)
      ass:append("{\\1c" .. seg_color .. "\\bord0\\alpha" .. seg_alpha .. "}")
      ass:draw_start()
      ass:rect_cw(seg_x_start, 0, seg_x_end, bar_height)
      ass:draw_stop()

      local seg_width = seg_x_end - seg_x_start
      if seg_width > 30 then
        ass:new_event()
        ass:an(5)
        ass:pos(bar_x + seg_x_start + seg_width / 2, bar_y + bar_height / 2)
        ass:append("{\\1c&HFFFFFF&\\3c&H000000&\\bord1\\shad0\\fs" .. fs_seg_label .. "\\b1}" .. idx)
      end

      if idx <= 3 and seg_width > 40 then
        ass:new_event()
        ass:an(1)
        ass:pos(bar_x + seg_x_start, bar_y + bar_height + 4)
        ass:append(
          "{\\1c&HDDDDDD&\\3c&H000000&\\bord1\\fs"
            .. (fs_seg_label - 2)
            .. "}"
            .. format_timestamp(seg.start_pos, false)
        )
      end
    end
  end

  local current_x = bar_x + (bar_width * progress_pct)

  ass:new_event()
  ass:an(7)
  ass:pos(current_x, bar_y - math.max(10, math.floor(bar_height * 1.1)))
  ass:append("{\\1c&HFFFFFF&\\bord1\\3c&H000000&}")
  ass:draw_start()
  ass:move_to(0, 0)
  ass:line_to(-tri_w, -tri_h)
  ass:line_to(tri_w, -tri_h)
  ass:line_to(0, 0)
  ass:draw_stop()

  ass:new_event()
  ass:an(5)
  ass:pos(current_x, bar_y - triangle_offset - math.floor(fs_current * 0.35))
  ass:append(
    "{\\1c&HFFFFFF&\\3c&H000000&\\bord2\\shad1\\fs"
      .. fs_current
      .. "\\b1}Current: "
      .. format_timestamp(current_pos, false)
  )

  ass:new_event()
  ass:an(5)
  ass:pos(bar_x + bar_width / 2, bar_y - triangle_offset - fs_current - 8)
  ass:append(
    "{\\1c&HBFBFBF&\\3c&H000000&\\bord2\\shad1\\fs" .. fs_total .. "}Total: " .. format_timestamp(duration, false)
  )

  overlay.data = ass.text
  overlay.res_x = osd_w
  overlay.res_y = osd_h
  overlay.z = 1000
  overlay:update()
  TimelineOverlay._force_update = nil
end

local function toggle_timeline_overlay()
  TimelineOverlay.enabled = not TimelineOverlay.enabled
  local overlay = TimelineOverlay.overlay_id
  if not TimelineOverlay.enabled and overlay then
    overlay.data = ""
    overlay:update()
  else
    update_timeline_overlay()
  end
  osd("Timeline overlay: " .. (TimelineOverlay.enabled and "ON" or "OFF") .. " | " .. mode_status_text(), 2)
end

-- ============================================================================
-- SETTINGS MENU
-- ============================================================================

local SettingsMenu = {
  active = false,
  selected = 1,
  overlay = nil,
  options = {
    {
      name = "Format",
      values = { "mp4", "mkv", "webm" },
      current = 1,
      get = function() return o.encoding.format end,
      set = function(v) set_format(v) end,
    },
    {
      name = "Quality",
      values = { "fast", "balanced", "quality", "archive", "web", "mobile" },
      current = 2,
      get = function() return CurrentPreset end,
      set = function(v) apply_preset(v) end,
    },
    {
      name = "Video Codec",
      values = { "libx264", "libx265", "copy" },
      current = 1,
      get = function() return o.encoding.video.codec end,
      set = function(v) set_video_codec(v) end,
    },
    {
      name = "Audio Codec",
      values = { "aac", "opus", "copy" },
      current = 1,
      get = function() return o.encoding.audio.codec end,
      set = function(v) set_audio_codec(v) end,
    },
    {
      name = "Hardware Accel",
      values = { "off", "auto" },
      current = 1,
      get = function() return o.encoding.hardware.enabled and "auto" or "off" end,
      set = function(v) o.encoding.hardware.enabled = (v == "auto") end,
    },
    {
      name = "Max Quality",
      values = { "720", "1080", "1440", "2160" },
      current = 2,
      get = function() return tostring(o.youtube.max_quality) end,
      set = function(v) o.youtube.max_quality = v end,
    },
    {
      name = "Audio Only",
      values = { "off", "on" },
      current = 1,
      get = function() return o.encoding.audio_only and "on" or "off" end,
      set = function(v) set_audio_only(v == "on") end,
    },
    {
      name = "Compatibility",
      values = { "off", "on" },
      current = 2,
      get = function() return o.compatibility_mode and "on" or "off" end,
      set = function(v)
        o.compatibility_mode = (v == "on")
        if o.compatibility_mode then
          enforce_compatibility_mode()
        end
      end,
    },
  },
}

local function sync_menu_state()
  for _, opt in ipairs(SettingsMenu.options) do
    if opt.get then
      local cur_val = opt.get()
      if cur_val ~= nil then
        for i, v in ipairs(opt.values) do
          if v == cur_val then
            opt.current = i
            break
          end
        end
      end
    end
  end
end

local function render_settings_menu()
  if not SettingsMenu.overlay then
    SettingsMenu.overlay = mp.create_osd_overlay("ass-events")
  end

  local overlay = SettingsMenu.overlay
  if overlay then
    overlay.z = 2000
  end

  local lines = {
    "Settings Menu (UP/DOWN, LEFT/RIGHT, 0/Esc close, " .. key_value("key_settings_menu", "Shift+m") .. " toggle):",
  }

  for i, opt in ipairs(SettingsMenu.options) do
    local marker = (i == SettingsMenu.selected) and "> " or "  "
    table.insert(lines, string.format("%s%d. %s: %s", marker, i, opt.name, opt.values[opt.current]))
  end

  local osd_w, osd_h = OSD_CACHE.w, OSD_CACHE.h

  local font_size = math.max(36, math.floor(osd_h * 0.038))
  local text = table.concat(lines, "\n")
  local styled = string.format(
    "{\\an7\\pos(%d,%d)\\q2\\fs%d\\bord2\\shad1\\1c&HFFFFFF&\\3c&H101010&}%s",
    math.floor(osd_w * 0.05),
    math.floor(osd_h * 0.1),
    font_size,
    ass_escape(text)
  )

  if overlay then
    overlay.data = styled
    overlay:update()
  end
end

local function close_settings_menu()
  if not SettingsMenu.active then
    return
  end
  SettingsMenu.active = false

  mp.remove_key_binding("video_cutter_menu_up")
  mp.remove_key_binding("video_cutter_menu_down")
  mp.remove_key_binding("video_cutter_menu_left")
  mp.remove_key_binding("video_cutter_menu_right")
  mp.remove_key_binding("video_cutter_menu_close")

  for i = 0, #SettingsMenu.options do
    mp.remove_key_binding("video_cutter_select_" .. i)
  end

  local overlay = SettingsMenu.overlay
  if overlay then
    overlay:remove()
    SettingsMenu.overlay = nil
  end
end

local function move_selection(delta)
  if not SettingsMenu.active then
    return
  end
  local new_selected = SettingsMenu.selected + delta
  if new_selected < 1 then
    new_selected = #SettingsMenu.options
  elseif new_selected > #SettingsMenu.options then
    new_selected = 1
  end
  SettingsMenu.selected = new_selected
  render_settings_menu()
end

local function cycle_setting(direction)
  if not SettingsMenu.active then
    return
  end

  local opt = SettingsMenu.options[SettingsMenu.selected]
  local new_index = opt.current + direction

  if new_index < 1 then
    new_index = #opt.values
  elseif new_index > #opt.values then
    new_index = 1
  end

  opt.current = new_index
  local value = opt.values[new_index]
  -- Any setting change is a deliberate user action.
  mark_manually_changed()

  if opt.set then
    opt.set(value)
  end

  -- Re-sync every row from o.encoding before repainting: apply_preset and the
  -- setters above mutate format/codec/etc., and without this the visible rows
  -- (Format, Video Codec, ...) stay stale until the menu is closed and reopened.
  sync_menu_state()
  render_settings_menu()
end

local function toggle_settings_menu()
  if SettingsMenu.active then
    close_settings_menu()
  else
    sync_menu_state()
    SettingsMenu.active = true

    mp.add_forced_key_binding("UP", "video_cutter_menu_up", function()
      move_selection(-1)
    end, { repeatable = true })
    mp.add_forced_key_binding("DOWN", "video_cutter_menu_down", function()
      move_selection(1)
    end, { repeatable = true })
    mp.add_forced_key_binding("LEFT", "video_cutter_menu_left", function()
      cycle_setting(-1)
    end, { repeatable = true })
    mp.add_forced_key_binding("RIGHT", "video_cutter_menu_right", function()
      cycle_setting(1)
    end, { repeatable = true })
    mp.add_forced_key_binding("ESC", "video_cutter_menu_close", close_settings_menu)

    for i = 0, #SettingsMenu.options do
      local index = i
      mp.add_forced_key_binding(tostring(index), "video_cutter_select_" .. index, function()
        select_setting(index)
      end)
    end

    render_settings_menu()
  end
end

select_setting = function(num)
  if not SettingsMenu.active then
    return
  end
  if num >= 1 and num <= #SettingsMenu.options then
    SettingsMenu.selected = num
    render_settings_menu()
  elseif num == 0 then
    close_settings_menu()
  end
end

-- ============================================================================
-- TOGGLE FUNCTIONS
-- ============================================================================

local function toggle_mark()
  if check_processing() then
    return
  end
  local pos = get_property_number("time-pos")
  if not pos then
    return
  end
  if o.encoding.cut_pos then
    local shift, endpos = math.min(o.encoding.cut_pos, pos), math.max(o.encoding.cut_pos, pos)
    if cut_video(shift, endpos) then
      push_undo({ type = "clear_mark", cut_pos = o.encoding.cut_pos })
      o.encoding.cut_pos = nil
    end
  else
    push_undo({ type = "set_mark", cut_pos = pos })
    o.encoding.cut_pos = pos
    osd(string.format("Mark set at: %s", format_timestamp(pos, false)), 2)
  end
end

local function toggle_enabled_option(option_table, label)
  option_table.enabled = not option_table.enabled
  osd(label .. ": " .. (option_table.enabled and "ON" or "OFF"), 2)
end

local function toggle_audio()
  toggle_enabled_option(o.encoding.audio, "Audio")
end

local function toggle_subs()
  toggle_enabled_option(o.encoding.subtitles, "Subtitles")
end

local function toggle_gif_mode()
  local modes = { "auto", "always", "never" }
  local current_index = 1
  for i, mode in ipairs(modes) do
    if o.encoding.gif.mode == mode then
      current_index = i
      break
    end
  end
  o.encoding.gif.mode = modes[(current_index % 3) + 1]
  osd("GIF mode: " .. o.encoding.gif.mode, 2)
end

local function toggle_lossless()
  if o.compatibility_mode then
    o.compatibility_mode = false
    Logger.info("compatibility_mode disabled by lossless toggle")
  end
  set_lossless(not o.encoding.lossless)
  osd("Lossless: " .. (o.encoding.lossless and "ON" or "OFF"), 2)
  if o.encoding.lossless then
    osd("Warning: Lossless mode may reduce compatibility on some platforms", 3)
  end
end

local function toggle_hardware()
  o.encoding.hardware.enabled = not o.encoding.hardware.enabled
  osd("Hardware accel: " .. (o.encoding.hardware.enabled and "ON" or "OFF"), 2)
end
local function toggle_audio_only()
  set_audio_only(not o.encoding.audio_only)
  osd("Audio Only: " .. (o.encoding.audio_only and "ON" or "OFF"), 2)
end

local function preview_segment()
  if not o.encoding.cut_pos then
    osd("No mark set to preview", 2)
    return
  end
  local pos = get_property_number("time-pos")
  if not pos then
    return
  end

  local start_pos = math.min(o.encoding.cut_pos, pos)
  local end_pos = math.max(o.encoding.cut_pos, pos)

  mp.set_property("ab-loop-a", tostring(start_pos))
  mp.set_property("ab-loop-b", tostring(end_pos))
  mp.set_property("time-pos", tostring(start_pos))

  osd(
    string.format(
      "Previewing: %s to %s (press %s to clear the loop)",
      format_timestamp(start_pos),
      format_timestamp(end_pos),
      key_value("key_clear_mark", "C")
    ),
    3
  )
end

local function toggle_queue_mode()
  o.flags.queue_mode = not o.flags.queue_mode
  if not o.flags.queue_mode and o.flags.merge_mode then
    o.flags.merge_mode = false
    osd("Queue mode: OFF | Merge mode auto-disabled", 3)
    return
  end
  if o.flags.queue_mode then
    osd("Queue mode: ON (Shift+s start, Shift+e end, r render)", 3)
  else
    osd("Queue mode: OFF", 2)
  end
end

local function toggle_merge_mode()
  if not o.flags.queue_mode and not o.flags.merge_mode then
    o.flags.queue_mode = true
  end
  o.flags.merge_mode = not o.flags.merge_mode
  osd("Merge mode: " .. (o.flags.merge_mode and "ON" or "OFF") .. " | " .. mode_status_text(), 3)
end

local function clear_mark()
  local cleared = false
  if o.encoding.cut_pos then
    push_undo({ type = "clear_mark", cut_pos = o.encoding.cut_pos })
    o.encoding.cut_pos = nil
    cleared = true
  end

  if PendingSegmentStart then
    push_undo({ type = "clear_pending_start", pos = PendingSegmentStart })
    PendingSegmentStart = nil
    cleared = true
  end

  mp.set_property("ab-loop-a", "")
  mp.set_property("ab-loop-b", "")

  if cleared then
    osd("Cut position, pending start, and loop cleared")
  else
    osd("Nothing to clear")
  end
end

local function cancel_current_or_last_job()
  local target = JobQueue:get_latest_running_media_job()
  if target then
    JobQueue:cancel(target.id)
    osd("Cancelled job #" .. target.id, 2)
    return
  end
  osd("No running job to cancel", 2)
end

-- ============================================================================
-- QUEUE MODE OPERATIONS
-- ============================================================================

local function set_start()
  if not o.flags.queue_mode then
    osd("Enable queue mode first (press " .. key_value("key_toggle_queue", "Ctrl+q") .. ")", 2)
    return
  end

  local pos = get_property_number("time-pos")
  if not pos then
    return
  end

  PendingSegmentStart = pos
  push_undo({ type = "set_pending_start", pos = pos })
  osd("Start set at: " .. format_timestamp(pos, false), 2)
end

local function set_end()
  if not o.flags.queue_mode then
    osd("Enable queue mode first (press " .. key_value("key_toggle_queue", "Ctrl+q") .. ")", 2)
    return
  end

  if not PendingSegmentStart then
    osd("Set start first (Shift+s)", 2)
    return
  end

  local pos = get_property_number("time-pos")
  if not pos then
    return
  end

  local start_pos = math.min(PendingSegmentStart, pos)
  local end_pos = math.max(PendingSegmentStart, pos)

  if end_pos - start_pos < 0.1 then
    osd("Segment too short (min 0.1s)", 2)
    return
  end

  table.insert(Segments, { start_pos = start_pos, end_pos = end_pos })
  push_undo({ type = "add_segment", start_pos = start_pos, end_pos = end_pos })
  save_queue()

  osd(
    string.format(
      "Segment added: %s to %s (%d total)",
      format_timestamp(start_pos),
      format_timestamp(end_pos),
      #Segments
    ),
    3
  )

  PendingSegmentStart = nil
end

local function cleanup_temp_files(files)
  for _, filepath in ipairs(files or {}) do
    if filepath:find("_vctemp_") and utils.file_info(filepath) then
      os.remove(filepath)
    end
  end
end

local function merge_segments(segment_files, output_path, on_complete)
  if #segment_files < 2 then
    cleanup_temp_files(segment_files)
    osd("Need at least 2 segments to merge", 2)
    if on_complete then
      on_complete(false)
    end
    return
  end

  local list_path = utils.join_path(o.target_dir, "merge_list_" .. os.time() .. "_" .. math.random(1000, 9999) .. ".txt")
  local list_file, err = io.open(list_path, "w")
  if not list_file then
    cleanup_temp_files()
    osd("Failed to create merge list: " .. tostring(err), 3)
    if on_complete then
      on_complete(false)
    end
    return
  end

  local write_ok, write_err = pcall(function()
    for _, filepath in ipairs(segment_files) do
      if filepath:find("\n") or filepath:find("\r") then
        error("Concat demuxer does not support newlines in filenames: " .. filepath)
      end
      local escaped = filepath:gsub("\\", "/"):gsub("'", "'\\''")
      local ok, werr = list_file:write("file '" .. escaped .. "'\n")
      if not ok then
        error("Failed to write to merge list: " .. tostring(werr))
      end
    end
  end)

  if not write_ok then
    list_file:close()
    if utils.file_info(list_path) then
      os.remove(list_path)
    end
    cleanup_temp_files()
    osd("Failed to write merge list: " .. tostring(write_err), 3)
    Logger.error("Merge list write failed: " .. tostring(write_err))
    if on_complete then
      on_complete(false)
    end
    return
  end

  list_file:flush()
  list_file:close()

  local cmd = Command:new(o.paths.ffmpeg_path)
  cmd:arg("-f", "concat")
  cmd:arg("-safe", "0")
  cmd:arg("-i", list_path)
  cmd:arg("-c", "copy")
  cmd:arg(o.flags.overwrite and "-y" or "-n")
  cmd:arg(output_path)

  osd("Merging " .. #segment_files .. " segments...", 3)

  cmd:run({
    job_type = "media",
    operation = "merge",
    output_path = output_path,
  }, function(job_id, result)
    if utils.file_info(list_path) then
      os.remove(list_path)
    end
    cleanup_temp_files()
    if result.success and utils.file_info(output_path) then
      osd("Merge complete: " .. output_path, 3)
      Logger.info("Merged segments to: " .. output_path)
      if on_complete then
        on_complete(true)
      end
    else
      osd("Merge failed: " .. tostring(result.error), 3)
      Logger.error("Merge failed: " .. tostring(result.error))
      if on_complete then
        on_complete(false)
      end
    end
  end)
end

local function render_queue()
  if State.queue_rendering then
    osd("Queue render already in progress", 2)
    return
  end

  if not o.flags.queue_mode then
    osd("Enable queue mode first (press Ctrl+q)", 2)
    return
  end

  if #Segments == 0 then
    osd("No segments in queue", 2)
    return
  end

  State.queue_rendering = true

  if o.flags.merge_mode then
    osd("Rendering " .. #Segments .. " segments for merge...", 3)

    local segments_to_render = copy_array(Segments)
    local segment_files = {}
    local completed_count = 0
    local failed = false

    local function process_next_segment(index)
      if index > #segments_to_render then
        if not failed and #segment_files >= 2 then
          local basename = get_property("filename/no-ext") or "merged"
          local ext = o.encoding.format
          local merged_name = basename .. "_merged." .. ext
          if o.naming and o.naming.auto_increment then
            local n = 1
            local candidate = sanitize_filename(basename .. "_merged_" .. n .. "." .. ext)
            local test_path = utils.join_path(o.target_dir, candidate)
            while utils.file_info(test_path) and not o.flags.overwrite do
              n = n + 1
              candidate = sanitize_filename(basename .. "_merged_" .. n .. "." .. ext)
              test_path = utils.join_path(o.target_dir, candidate)
            end
            merged_name = candidate
          else
            merged_name = sanitize_filename(merged_name)
          end
          local merged_path = utils.join_path(o.target_dir, merged_name)
          merge_segments(segment_files, merged_path, function(success)
            if success then
              Segments = {}
              save_queue()
            else
              osd("Merge queue kept unchanged due to errors", 3)
            end
            State.queue_rendering = false
          end)
        elseif not failed then
          osd("Only 1 segment rendered, no merge needed", 2)
          Segments = {}
          save_queue()
          State.queue_rendering = false
        else
          osd("Merge queue kept unchanged due to errors", 3)
          cleanup_temp_files(segment_files)
          State.queue_rendering = false
        end
        return
      end

      local seg = segments_to_render[index]
      local outpath = get_outname(seg.start_pos, seg.end_pos)

      local ext = outpath:match("(%.[^%.]+)$") or ""
      local base = ext ~= "" and outpath:sub(1, #outpath - #ext) or outpath
      local temp_path = string.format("%s_vctemp_%d%s", base, index, ext)

      local stream_type = get_stream_type()
      local inpath = get_property("path")
      local is_local = stream_type == "local_file" or utils.file_info(inpath) ~= nil

      if not is_local and stream_type ~= "hls" then
        Logger.warn("Merge mode with remote streams: downloading segment " .. index)
        osd("Downloading remote segment " .. index .. "/" .. #segments_to_render .. "...", 3)

        local function handle_remote_complete(success)
          if success and utils.file_info(temp_path) then
            table.insert(segment_files, temp_path)
            completed_count = completed_count + 1
            osd(string.format("Downloaded %d/%d segments...", completed_count, #segments_to_render), 2)
            process_next_segment(index + 1)
          else
            failed = true
            osd("Remote segment " .. index .. " download failed", 3)
            process_next_segment(#segments_to_render + 1)
          end
        end

        local merge_inpath = inpath
        if merge_inpath and merge_inpath:match("^ytdl://") then
          merge_inpath = merge_inpath:gsub("^ytdl://", "")
        end

        process_remote_segment(seg.start_pos, seg.end_pos, temp_path, merge_inpath, handle_remote_complete, true)
        return
      end

      local cmd, err = build_ffmpeg_command(seg.start_pos, seg.end_pos, temp_path)
      if not cmd then
        osd("Error: " .. (err or "Failed to build command"), 3)
        failed = true
        cleanup_temp_files(segment_files)
        State.queue_rendering = false
        return
      end

      cmd:set_overwrite(true)

      cmd:run({
        job_type = "media",
        operation = "cut",
        is_intermediate = true,
        output_path = temp_path,
        duration = seg.end_pos - seg.start_pos,
      }, function(job_id, result)
        if result.success then
          completed_count = completed_count + 1
          table.insert(segment_files, temp_path)
          osd(string.format("Rendered %d/%d segments...", completed_count, #segments_to_render), 2)
          process_next_segment(index + 1)
        else
          failed = true
          osd("Segment " .. index .. " failed: " .. tostring(result.error), 3)
          cleanup_temp_files(segment_files)
          State.queue_rendering = false
        end
      end)
    end

    process_next_segment(1)
  else
    osd("Rendering " .. #Segments .. " segments...", 3)
    local segments_to_render = copy_array(Segments)
    local stream_type = get_stream_type()
    local inpath = get_property("path")
    local is_local = stream_type == "local_file" or utils.file_info(inpath) ~= nil
    local is_remote = not is_local and stream_type ~= "hls"
    local queue_failed = false
    local completed_count = 0

    if is_remote then
      local queue_inpath = inpath
      if queue_inpath and queue_inpath:match("^ytdl://") then
        queue_inpath = queue_inpath:gsub("^ytdl://", "")
      end

      local function process_remote_segment_queue(index)
        if index > #segments_to_render then
          if not queue_failed then
            Segments = {}
            save_queue()
            osd("All segments rendered", 2)
            send_notification("Video Cutter", "Queue rendering completed successfully!")
            if o.output.auto_open and LastOutputPath then
              open_output_folder(LastOutputPath)
            end
          else
            osd("Queue kept unchanged due to errors", 3)
          end
          State.queue_rendering = false
          return
        end

        local seg = segments_to_render[index]
        local outpath = get_outname(seg.start_pos, seg.end_pos)

        osd(string.format("Remote segment %d/%d...", index, #segments_to_render), 2)

        process_remote_segment(seg.start_pos, seg.end_pos, outpath, queue_inpath, function(success)
          if success then
            cleanup_ytdlp_numbered_files(outpath)
            if utils.file_info(outpath) then
              LastOutputPath = outpath
            end
            completed_count = completed_count + 1
            osd(string.format("Downloaded %d/%d segments...", completed_count, #segments_to_render), 2)
            process_remote_segment_queue(index + 1)
          else
            queue_failed = true
            osd("Remote segment " .. index .. " failed", 3)
            State.queue_rendering = false
            process_remote_segment_queue(#segments_to_render + 1)
          end
        end, true)
      end

      process_remote_segment_queue(1)
    else
      local seg_index = 1

      local function process_local_segment()
        if seg_index > #segments_to_render then
          Segments = {}
          save_queue()
          osd("All segments rendered", 2)
          send_notification("Video Cutter", "Queue rendering completed successfully!")
          if o.output.auto_open and LastOutputPath then
            open_output_folder(LastOutputPath)
          end
          State.queue_rendering = false
          return
        end

        local seg = segments_to_render[seg_index]
        local outpath = get_outname(seg.start_pos, seg.end_pos)

        local cmd, err = build_ffmpeg_command(seg.start_pos, seg.end_pos, outpath)
        if not cmd then
          osd("Error: " .. (err or "Failed to build command"), 3)
          State.queue_rendering = false
          return
        end

        osd(string.format("Rendering segment %d/%d...", seg_index, #segments_to_render), 2)

        cmd:run({
          job_type = "media",
          operation = "cut",
          is_intermediate = true,
          output_path = outpath,
          duration = seg.end_pos - seg.start_pos,
        }, function(job_id, result)
          if result.success then
            if utils.file_info(outpath) then
              LastOutputPath = outpath
            end
            seg_index = seg_index + 1
            process_local_segment()
          else
            Logger.error("Queued segment job failed: #" .. tostring(job_id))
            osd("Segment " .. seg_index .. " failed, queue preserved for retry", 3)
            State.queue_rendering = false
          end
        end)
      end

      process_local_segment()
    end
  end
end

-- ============================================================================
-- STATUS HUD
-- ============================================================================

render_hud = function()
  if not HudOverlay then
    HudOverlay = mp.create_osd_overlay("ass-events")
  end

  local mark_str = o.encoding.cut_pos and format_timestamp(o.encoding.cut_pos, false) or "--:--:--"
  local pending_str = PendingSegmentStart and format_timestamp(PendingSegmentStart, false) or "--:--:--"
  local job_str = State.processing and string.format("PROCESSING %d%%", math.floor(State.progress or 0)) or "IDLE"
  local stats = JobQueue:get_stats()
  local stream_type = get_stream_type()
  local is_live = is_live_stream()
  local uptime_str = ""
  if is_live then
    local uptime = get_stream_uptime()
    if uptime then
      uptime_str = "Uptime: " .. format_duration(uptime) .. " | "
    end
  end

  local ass_text = string.format(
    "{\\an7}{\\fs16}{\\c&H00FFFF&}--- Video Cutter Status ---\\N"
      .. "{\\c&HFFFFFF&}Type: {\\c&H00FF00&}%s%s{\\c&HFFFFFF&} | "
      .. "%s"
      .. "Mark: {\\c&H00FF00&}%s\\N"
      .. "{\\c&HFFFFFF&}Audio: {\\c&H%s&}%s{\\c&HFFFFFF&} | "
      .. "Subs: {\\c&H%s&}%s{\\c&HFFFFFF&} | "
      .. "GIF: {\\c&H%s&}%s\\N"
      .. "{\\c&HFFFFFF&}Lossless: {\\c&H%s&}%s{\\c&HFFFFFF&} | "
      .. "HW: {\\c&H%s&}%s{\\c&HFFFFFF&} | "
      .. "Audio Only: {\\c&H%s&}%s{\\c&HFFFFFF&} | "
      .. "Preset: {\\c&H00FF00&}%s\\N"
      .. "{\\c&HFFFFFF&}Format: {\\c&H00FF00&}%s{\\c&HFFFFFF&} | "
      .. "Jobs: {\\c&H00FF00&}%d{\\c&HFFFFFF&} | "
      .. "Segments: {\\c&H00FF00&}%d\\N"
      .. "{\\c&HFFFFFF&}Modes: Queue={\\c&H%s&}%s{\\c&HFFFFFF&} | "
      .. "Merge={\\c&H%s&}%s{\\c&HFFFFFF&} | "
      .. "Timeline={\\c&H%s&}%s\\N"
      .. "{\\c&HFFFFFF&}"
      .. "Pending start: {\\c&H00FF00&}%s{\\c&HFFFFFF&} | "
      .. "Job: {\\c&H%s&}%s",
    stream_type:gsub("_", " "):upper(),
    is_live and " {\\c&HFF0000&}[LIVE]{\\c&HFFFFFF&}" or "",
    uptime_str,
    mark_str,
    o.encoding.audio.enabled and "00FF00" or "FF0000",
    o.encoding.audio.enabled and "ON" or "OFF",
    o.encoding.subtitles.enabled and "00FF00" or "FF0000",
    o.encoding.subtitles.enabled and "ON" or "OFF",
    o.encoding.gif.mode == "always" and "00FF00" or (o.encoding.gif.mode == "auto" and "FFFF00" or "FF0000"),
    o.encoding.gif.mode:upper(),
    o.encoding.lossless and "00FF00" or "FF0000",
    o.encoding.lossless and "ON" or "OFF",
    o.encoding.hardware.enabled and "00FF00" or "FF0000",
    o.encoding.hardware.enabled and (HardwareAccelDetected or "ON") or "OFF",
    o.encoding.audio_only and "00FF00" or "FF0000",
    o.encoding.audio_only and "ON" or "OFF",
    CurrentPreset or "default",
    o.encoding.format,
    stats.pending + stats.running,
    #Segments,
    o.flags.queue_mode and "00FF00" or "FF0000",
    o.flags.queue_mode and "ON" or "OFF",
    o.flags.merge_mode and "00FF00" or "FF0000",
    o.flags.merge_mode and "ON" or "OFF",
    TimelineOverlay.enabled and "00FF00" or "FF0000",
    TimelineOverlay.enabled and "ON" or "OFF",
    pending_str,
    State.processing and "FFFF00" or "00FF00",
    job_str
  )

  HudOverlay.data = ass_text
  HudOverlay:update()
end

hide_status_hud = function()
  if HudOverlay then
    HudOverlay.data = ""
    HudOverlay:update()
  end
end

local function show_status_hud()
  if not HudOverlay then
    HudOverlay = mp.create_osd_overlay("ass-events")
  end

  if HudOverlay.data and HudOverlay.data ~= "" then
    hide_status_hud()
    return
  end

  render_hud()
end

local function update_hud()
  if o.hud.enabled and HudOverlay and HudOverlay.data and HudOverlay.data ~= "" then
    render_hud()
  end
end

local function show_state()
  local job_status = State.processing and "running" or "idle"
  local stats = JobQueue:get_stats()
  local stream_type = get_stream_type()
  local is_live = is_live_stream()
  local live_text = is_live and " | LIVE: yes" or ""
  local uptime_text = ""
  if is_live then
    local uptime = get_stream_uptime()
    if uptime then
      uptime_text = string.format(" | Uptime: %s", format_duration(uptime))
    end
  end
  osd(
    string.format(
      "Type: %s%s%s | Mark: %s | Pending: %s | Audio: %s | Subs: %s | GIF: %s | Lossless: %s | HW: %s | Audio Only: %s | QueueMode: %s | MergeMode: %s | Segments: %d | Jobs: %d | Job: %s",
      stream_type:gsub("_", " "):upper(),
      live_text,
      uptime_text,
      o.encoding.cut_pos and format_timestamp(o.encoding.cut_pos) or "None",
      PendingSegmentStart and format_timestamp(PendingSegmentStart) or "None",
      o.encoding.audio.enabled and "On" or "Off",
      o.encoding.subtitles.enabled and "On" or "Off",
      o.encoding.gif.mode,
      o.encoding.lossless and "On" or "Off",
      o.encoding.hardware.enabled and (HardwareAccelDetected or "On") or "Off",
      o.encoding.audio_only and "On" or "Off",
      o.flags.queue_mode and "On" or "Off",
      o.flags.merge_mode and "On" or "Off",
      #Segments,
      stats.pending + stats.running,
      job_status
    ),
    5
  )
end

-- ============================================================================
-- HELP OVERLAY
-- ============================================================================

local function hide_help()
  HelpOverlayVisible = false
  if HelpOverlayTimer then
    HelpOverlayTimer:kill()
    HelpOverlayTimer = nil
  end
  osd("")
end

local function show_help()
  if HelpOverlayVisible then
    hide_help()
    return
  end

  HelpOverlayVisible = true
  local function key(k)
    return "[" .. k .. "]"
  end
  local function sec(title)
    return title .. ":"
  end
  local help_lines =
    {
      "Video Cutter v" .. SCRIPT_VERSION .. " (" .. key(key_value("key_show_help", "?")) .. " close)",
      "",
      sec("Core Controls"),
      "  " .. key(key_value("key_toggle_mark", "c")) .. " set/finish mark    " .. key(
        key_value("key_toggle_audio", "a")
      ) .. " audio    " .. key(key_value("key_toggle_subs", "Ctrl+s")) .. " subs    " .. key(
        key_value("key_toggle_gif", "g")
      ) .. " gif",
      "  "
        .. key(key_value("key_show_state", "i"))
        .. " state    "
        .. key(key_value("key_show_hud", "h"))
        .. " HUD    "
        .. key(key_value("key_show_help", "?"))
        .. " help",
      "",
      sec("Cut"),
      "  "
        .. key(key_value("key_toggle_mark", "c"))
        .. " set/finish mark    "
        .. key(key_value("key_clear_mark", "C"))
        .. " clear mark    "
        .. key(key_value("key_execute_cut", "Shift+x"))
        .. " cut mark->current    "
        .. key(key_value("key_preview_segment", "Shift+p"))
        .. " preview",
      sec("Queue"),
      "  " .. key(key_value("key_toggle_queue", "Ctrl+q")) .. " queue mode    " .. key(
        key_value("key_set_start", "Shift+s")
      ) .. " start    " .. key(key_value("key_set_end", "Shift+e")) .. " end    " .. key(
        key_value("key_render_queue", "r")
      ) .. " render (supports remote streams)",
      sec("Modes/Toggles"),
      "  " .. key(key_value("key_toggle_merge", "Ctrl+m")) .. " merge    " .. key(
        key_value("key_toggle_timeline", "t")
      ) .. " timeline    " .. key(key_value("key_settings_menu", "Shift+m")) .. " settings",
      "  "
        .. key(key_value("key_toggle_audio", "a"))
        .. " audio    "
        .. key(key_value("key_toggle_subs", "Ctrl+s"))
        .. " subs    "
        .. key(key_value("key_toggle_gif", "g"))
        .. " gif    "
        .. key(key_value("key_toggle_lossless", "Ctrl+l"))
        .. " lossless    "
        .. key(key_value("key_toggle_hardware", "H"))
        .. " hw    "
        .. key(key_value("key_toggle_audio_only", "Shift+a"))
        .. " audio only",
      sec("Actions/Info"),
      "  "
        .. key(key_value("key_cancel_job", "x"))
        .. " cancel    "
        .. key(key_value("key_undo", "u"))
        .. " undo    "
        .. key(key_value("key_open_output", "o"))
        .. " output    "
        .. key(key_value("key_cycle_preset", "p"))
        .. " preset    "
        .. key(key_value("key_show_state", "i"))
        .. " state    "
        .. key(key_value("key_show_hud", "h"))
        .. " HUD",
      sec("Persistence"),
      "  " .. key(key_value("key_save_settings", "Ctrl+Alt+s")) .. " save    " .. key(
        key_value("key_load_settings", "Ctrl+Alt+l")
      ) .. " load    " .. key(key_value("key_export_cuts", "Ctrl+Alt+e")) .. " export",
      "",
      "Current: format="
        .. o.encoding.format
        .. " | preset="
        .. (CurrentPreset or "default")
        .. " | queue="
        .. (o.flags.queue_mode and "ON" or "OFF")
        .. " | merge="
        .. (o.flags.merge_mode and "ON" or "OFF"),
    }
  local help_text = table.concat(help_lines, "\n")

  osd(help_text, 10)

  if HelpOverlayTimer then
    HelpOverlayTimer:kill()
  end
  HelpOverlayTimer = mp.add_timeout(10, hide_help)
end

-- ============================================================================
-- PRESETS
-- ============================================================================

apply_preset = function(name)
  local preset = o.presets[name]
  if not preset then
    osd("Preset not found: " .. name, 2)
    return false
  end

  if preset.vcodec then
    set_video_codec(preset.vcodec)
  end
  if preset.format then
    set_format(preset.format)
  end
  if preset.bitrate then
    o.encoding.video.bitrate = preset.bitrate
  end
  if preset.preset then
    o.encoding.video.preset = preset.preset
  end
  if preset.crf then
    o.encoding.video.crf = preset.crf
  end
  if preset.fps then
    o.encoding.gif.fps = preset.fps
  end
  if preset.scale then
    o.encoding.gif.scale = preset.scale
  end
  if preset.mode then
    o.encoding.gif.mode = preset.mode
  end

  CurrentPreset = name
  State.settings_manually_changed = true
  osd("Applied preset: " .. name)
  return true
end

local function cycle_preset()
  local preset_names = {}
  for name, _ in pairs(o.presets) do
    table.insert(preset_names, name)
  end
  table.sort(preset_names)

  if #preset_names == 0 then
    osd("No presets defined", 2)
    return
  end

  local current_index = 0
  for i, name in ipairs(preset_names) do
    if name == CurrentPreset then
      current_index = i
      break
    end
  end

  local next_preset = preset_names[(current_index % #preset_names) + 1]
  apply_preset(next_preset)
end

-- ============================================================================
-- HARDWARE AUTO-DETECTION
-- ============================================================================

-- Cache of the available hardware encoder FAMILY (NVENC/QSV/VAAPI/VideoToolbox/AMF).
-- Detected once at startup; the per-codec encoder NAME is derived at build time
-- so changing the video codec (libx264 -> libx265) actually switches the HW
-- encoder instead of being frozen at the startup value.
-- Derive the codec prefix ("h264_" or "hevc_") from a software codec name.
local function hardware_prefix_for(codec)
  codec = codec or ""
  if codec:match("265") or codec:match("hevc") or codec:match("h265") then
    return "hevc_"
  end
  return "h264_"
end

-- Resolve the concrete HW encoder name for the currently selected software codec,
-- or nil if no HW encoder of the detected family is available for this codec.
hardware_encoder_for = function(codec)
  local family = HardwareAccelFamily
  if not family or family == "software" then
    return nil
  end
  local prefix = hardware_prefix_for(codec)
  local families = {
    NVENC = "nvenc",
    QSV = "qsv",
    VAAPI = "vaapi",
    VideoToolbox = "videotoolbox",
    AMF = "amf",
  }
  local suffix = families[family]
  if not suffix then
    return nil
  end
  -- Validate that the family detector actually saw an encoder for this prefix.
  -- (Family was detected against the startup codec; libx265 may not have an
  -- encoder on this build even if libx264's HW encoder exists.)
  if HardwareAccelEncoders and HardwareAccelEncoders[prefix .. suffix] then
    return prefix .. suffix
  end
  return nil
end

-- One-time detection of the available hardware encoder family and the set of
-- HW encoder names reported by this ffmpeg build. Cached for the script
-- lifetime; the per-codec encoder NAME is resolved lazily per build.
detect_hardware_accel = function()
  if HardwareAccelFamily then
    return HardwareAccelFamily
  end

  local res = mp.command_native({
    name = "subprocess",
    args = { o.paths.ffmpeg_path, "-encoders" },
    playback_only = false,
    capture_stdout = true,
    capture_stderr = true,
  })

  if not res or res.status ~= 0 then
    HardwareAccelFamily = "software"
    HardwareAccelDetected = "software"
    Logger.warn("Failed to query ffmpeg encoders for hardware detection")
    return HardwareAccelFamily
  end

  local output = (res.stdout or "") .. "\n" .. (res.stderr or "")

  -- Index every encoder name ffmpeg reports, so per-codec resolution later
  -- can confirm a specific encoder exists instead of assuming family coverage.
  HardwareAccelEncoders = {}
  for name in output:gmatch("%s[VLA]%S+%s+([^%s]+)") do
    if
      name:match("nvenc")
      or name:match("qsv")
      or name:match("vaapi")
      or name:match("videotoolbox")
      or name:match("amf")
    then
      HardwareAccelEncoders[name] = true
    end
  end

  -- Pick the first available family, in preference order.
  local order = { "nvenc", "qsv", "vaapi", "videotoolbox", "amf" }
  local labels = {
    nvenc = "NVENC",
    qsv = "QSV",
    vaapi = "VAAPI",
    videotoolbox = "VideoToolbox",
    amf = "AMF",
  }
  for _, suffix in ipairs(order) do
    -- Match against any codec prefix so a build with only hevc_nvenc
    -- still registers NVENC.
    if output:match("h264_" .. suffix) or output:match("hevc_" .. suffix) then
      HardwareAccelFamily = labels[suffix]
      HardwareAccelDetected = labels[suffix]
      -- Back-compat: keep the startup codec's encoder name in the config
      -- field; build paths resolve the real encoder per-codec instead.
      o.encoding.hardware.encoder = hardware_encoder_for(o.encoding.video.codec) or ("h264_" .. suffix)
      Logger.info("Hardware acceleration detected: " .. HardwareAccelFamily)
      return HardwareAccelFamily
    end
  end

  HardwareAccelFamily = "software"
  HardwareAccelDetected = "software"
  Logger.info("Hardware acceleration detected: software")
  return HardwareAccelFamily
end

-- ============================================================================
-- AUTO-OPEN OUTPUT
-- ============================================================================

-- Launch a "reveal this file/folder" command detached, so mpv is never blocked
-- by xdg-open / open / explorer waiting on the spawned helper process.
local function try_open_command(cmd)
  local res = mp.command_native({
    name = "subprocess",
    args = cmd,
    playback_only = false,
    detach = true,
    -- capture is moot under detach but harmless
  })
  return res and res.status == 0
end

open_output_folder = function(path, force)
  if not path or (not force and not o.output.auto_open) then
    return
  end

  local folder = select(1, utils.split_path(path))
  local target = o.output.open_file and path or folder

  if is_windows then
    -- explorer /select expects the flag and path as ONE argv token:
    -- "/select,<path>". Passing them as separate args leaks "/select," as a
    -- stray token and the file is not selected.
    local cmd = o.output.open_file and { "explorer", "/select," .. path } or { "explorer", folder }
    local success, err = pcall(function()
      mp.command_native({ name = "subprocess", args = cmd, detach = true })
    end)
    if not success then
      Logger.error("Failed to open output: " .. tostring(err))
    else
      Logger.info("Opened output: " .. target)
    end
    return
  end

  -- Unix: prefer xdg-open, fall back to `open` (macOS). Both run detached
  -- so mpv is never blocked on the helper.
  if try_open_command({ "xdg-open", target }) then
    Logger.info("Opened output: " .. target)
    return
  end
  if try_open_command({ "open", target }) then
    Logger.info("Opened output: " .. target)
    return
  end
  Logger.warn("No suitable program to open output folder")
end

local function open_last_output()
  if not LastOutputPath or LastOutputPath == "" then
    osd("No output file available yet", 2)
    return
  end
  open_output_folder(LastOutputPath, true)
end

-- ============================================================================
-- PERSISTENCE FUNCTIONS
-- ============================================================================

-- Persist only the user-tunable encoding fields, not transient runtime state
-- (cut_pos, hardware.encoder snapshot, etc.), so the settings file stays clean
-- and a stale mark or detected encoder never gets resurrected on load.
local function snapshot_persistable_encoding()
  return {
    format = o.encoding.format,
    video = {
      codec = o.encoding.video.codec,
      bitrate = o.encoding.video.bitrate,
      fps = o.encoding.video.fps,
      crf = o.encoding.video.crf,
      preset = o.encoding.video.preset,
    },
    audio = {
      enabled = o.encoding.audio.enabled,
      codec = o.encoding.audio.codec,
      bitrate = o.encoding.audio.bitrate,
    },
    gif = {
      fps = o.encoding.gif.fps,
      scale = o.encoding.gif.scale,
      mode = o.encoding.gif.mode,
    },
    subtitles = { enabled = o.encoding.subtitles.enabled },
    hardware = {
      enabled = o.encoding.hardware.enabled,
      decoder = o.encoding.hardware.decoder,
      device = o.encoding.hardware.device,
      quality_preset = o.encoding.hardware.quality_preset,
      -- encoder is deliberately omitted: it's auto-detected per ffmpeg build
      -- and resolved per-codec at build time.
    },
    lossless = o.encoding.lossless,
    apply_filters = o.encoding.apply_filters,
    audio_only = o.encoding.audio_only,
    custom_ffmpeg_args = o.encoding.custom_ffmpeg_args,
  }
end

local function save_settings()
  local settings = {
    version = SCRIPT_VERSION,
    encoding = snapshot_persistable_encoding(),
    output_template = o.output.template,
    current_preset = CurrentPreset,
    compatibility_mode = o.compatibility_mode,
    saved_at = os.date("%Y-%m-%d %H:%M:%S"),
  }

  local settings_path = utils.join_path(o.target_dir, ".video_cutter_settings.json")
  local ok, err = pcall(function()
    local file, open_err = io.open(settings_path, "w")
    if not file then
      error("Failed to open settings file: " .. tostring(open_err))
    end
    local write_ok, write_err = file:write(utils.format_json(settings))
    if not write_ok then
      file:close()
      error("Failed to write settings: " .. tostring(write_err))
    end
    file:close()
  end)

  if ok then
    osd("Settings saved to " .. settings_path, 3)
  else
    osd("Failed to save settings: " .. tostring(err), 2)
    Logger.error("Settings save failed: " .. tostring(err))
  end
end

local function load_settings(user_initiated)
  user_initiated = user_initiated or false
  local settings_path = utils.join_path(o.target_dir, ".video_cutter_settings.json")
  local ok, result = pcall(function()
    local file, open_err = io.open(settings_path, "r")
    if not file then
      return nil
    end
    local content = file:read("*a")
    file:close()
    return utils.parse_json(content)
  end)

  if not ok or not result then
    if user_initiated then
      osd("No saved settings found", 2)
    end
    return
  end

  -- Discard old settings from previous script versions to prevent config conflicts
  if result.version ~= SCRIPT_VERSION then
    Logger.info(
      "Discarding old settings file from v"
        .. tostring(result.version or "unknown")
        .. " to apply v"
        .. SCRIPT_VERSION
        .. " defaults."
    )
    os.remove(settings_path)
    if user_initiated then
      osd("Legacy settings file discarded (version mismatch)", 3)
    end
    return
  end

  if result.encoding then
    -- Strip transient/runtime fields a legacy file might still carry, so they
    -- never get merged back in. New files don't contain them (whitelisted on
    -- save), but old files written by prior versions can.
    local enc = result.encoding
    enc.cut_pos = nil
    if enc.hardware then
      enc.hardware.encoder = nil
    end
    o.encoding = table_merge(o.encoding, enc)
  end
  if result.output_template then
    o.output.template = result.output_template
  end
  -- A loaded settings file is the user's explicit configuration, so it
  -- takes precedence over per-source defaults for the rest of the session.
  State.settings_manually_changed = true
  -- Restore the saved compatibility mode (absent in legacy files, which keep
  -- the conf/script default), then enforce only if it is actually on.
  if result.compatibility_mode ~= nil then
    o.compatibility_mode = (result.compatibility_mode == true or result.compatibility_mode == "yes")
  end
  if o.compatibility_mode then
    enforce_compatibility_mode()
  end
  osd("Settings loaded from " .. settings_path, 3)
end

local function export_cuts()
  if #Segments == 0 then
    osd("No segments to export", 2)
    return
  end

  local export_path = utils.join_path(o.target_dir, "video_cutter_export_" .. os.date("%Y%m%d_%H%M%S") .. ".txt")
  local ok, err = pcall(function()
    local file, open_err = io.open(export_path, "w")
    if not file then
      error("Failed to open export file: " .. tostring(open_err))
    end
    file:write("# Video Cutter Export\n")
    file:write("# Source: " .. (get_property("path") or "unknown") .. "\n")
    file:write("# Date: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")

    for i, seg in ipairs(Segments) do
      file:write(
        string.format(
          "Segment %d: %s - %s (duration: %s)\n",
          i,
          format_timestamp(seg.start_pos),
          format_timestamp(seg.end_pos),
          format_timestamp(seg.end_pos - seg.start_pos)
        )
      )
    end

    file:close()
  end)

  if ok then
    osd("Export saved to " .. export_path, 3)
  else
    osd("Failed to export cuts: " .. tostring(err), 2)
    Logger.error("Export failed: " .. tostring(err))
  end
end

-- ============================================================================
-- SOURCE DEFAULTS
-- ============================================================================

local function apply_source_defaults(stream_type)
  if State and State.settings_manually_changed then
    return
  end

  local defaults = o.source_defaults[stream_type]
  if not defaults then
    Logger.debug("No defaults for stream type: " .. stream_type)
    return
  end

  if defaults.format then
    if o.compatibility_mode and defaults.format ~= "mp4" then
      Logger.debug("compatibility_mode on: ignoring " .. stream_type .. " default format '" .. defaults.format .. "'")
    else
      o.encoding.format = defaults.format
    end
  end
  if defaults.lossless ~= nil then
    if o.compatibility_mode and defaults.lossless then
      Logger.debug("compatibility_mode on: ignoring " .. stream_type .. " lossless default")
    else
      o.encoding.lossless = defaults.lossless
    end
  end
  if defaults.max_quality then
    o.youtube.max_quality = defaults.max_quality
  end

  Logger.info("Applied " .. stream_type .. " defaults")
end

-- ============================================================================
-- DEPENDENCY CHECK
-- ============================================================================

local function check_dependency(name, cmd, version_flag)
  version_flag = version_flag or "-version"

  local res = mp.command_native({
    name = "subprocess",
    args = { cmd, version_flag },
    playback_only = false,
    capture_stdout = true,
    capture_stderr = true,
  })

  if res and res.status == 0 then
    return true
  end

  if version_flag ~= "--version" then
    local alt = mp.command_native({
      name = "subprocess",
      args = { cmd, "--version" },
      playback_only = false,
      capture_stdout = true,
      capture_stderr = true,
    })
    if alt and alt.status == 0 then
      return true
    end
  end

  return false
end

local function check_all_dependencies()
  o.flags.ffmpeg_available = check_dependency("ffmpeg", o.paths.ffmpeg_path, "-version")
  o.flags.ytdlp_available = check_dependency("yt-dlp", "yt-dlp", "--version")

  if not o.flags.ffmpeg_available then
    Logger.error("FFmpeg not found. Install FFmpeg for video cutting.")
  else
    detect_hardware_accel()
  end
  if not o.flags.ytdlp_available then
    Logger.warn("yt-dlp not found. Remote stream cutting will not work.")
  end

  o.flags.dependencies_checked = true
  return o.flags.ffmpeg_available
end

-- ============================================================================
-- CLEANUP
-- ============================================================================

local function cleanup(e)
  o.encoding.cut_pos = nil
  State.processing = false
  State.progress = 0
  State.current_job_id = nil

  -- Abort live ffmpeg/yt-dlp subprocesses when MPV quits so orphaned
  -- processes are not left behind. Normal track change or end-of-file
  -- allows in-progress cuts to complete in the background.
  local abort_jobs = (e and e.reason == "quit")
  if abort_jobs and JobQueue then
    if JobQueue.active_subprocesses then
      for jid, handle in pairs(JobQueue.active_subprocesses) do
        if type(handle) ~= "boolean" and handle ~= nil then
          local job = JobQueue.jobs[jid]
          if job then
            job.cancel_requested = true
            job.state = "cancelled"
            job.completed_at = os.time()
            -- Remove partial output so aborted jobs leave no garbage behind.
            remove_job_outputs(job)
          end
          pcall(mp.abort_async_command, handle)
        end
      end
    end
    for _, jid in ipairs(JobQueue.order or {}) do
      local job = JobQueue.jobs[jid]
      if job and (job.state == "pending" or job.state == "running") then
        job.state = "cancelled"
      end
    end
    JobQueue.running_job_id = nil
    JobQueue.active_subprocesses = {}
  end

  if HudTimer then
    HudTimer:kill()
    HudTimer = nil
  end

  if TimelineOverlay.observers_added then
    mp.unobserve_property(update_timeline_overlay)
    mp.unobserve_property(on_osd_width_change)
    mp.unobserve_property(on_osd_height_change)
    TimelineOverlay.observers_added = false
  end

  hide_status_hud()
  hide_help()
  clear_message_overlay()
  close_settings_menu()
end

-- ============================================================================
-- KEY BINDINGS
-- ============================================================================

local function add_user_binding(option_name, fallback, bind_name, handler)
  local key = key_value(option_name, fallback)
  if key ~= "" then
    mp.add_key_binding(key, bind_name, handler)
  end
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

-- Named observers (not anonymous closures) so cleanup can unobserve them and
-- re-adding them on each file load doesn't accumulate duplicate callbacks.
on_osd_width_change = function(_, w)
  if w and w > 0 then
    OSD_CACHE.w = w
  end
  update_timeline_overlay()
end

on_osd_height_change = function(_, h)
  if h and h > 0 then
    OSD_CACHE.h = h
  end
  update_timeline_overlay()
end

local function on_file_loaded()
  local stream_type = get_stream_type()
  local is_live = is_live_stream()
  apply_source_defaults(stream_type)

  if is_live then
    Logger.info("LIVE stream detected: type=" .. stream_type)
  else
    Logger.info("File loaded: type=" .. stream_type)
  end

  -- Reset per-file transient state so switching sources doesn't leak
  -- undo history or a pending start from the previous file.
  UndoStack = {}
  PendingSegmentStart = nil

  -- Restore persisted segment queue for this source (per-source hash file).
  -- end-file cleanup does not clear Segments, so switching sources would
  -- otherwise leak the previous file's segments into the new one.
  Segments = {}
  local restored = load_queue()
  if restored and restored > 0 then
    Logger.info(string.format("Restored %d queued segments for this source", restored))
    TimelineOverlay._force_update = true
  end

  if o.hud.enabled and not HudTimer then
    HudTimer = mp.add_periodic_timer(o.hud.update_interval or 1.0, update_hud)
  end

  if not TimelineOverlay.observers_added then
    mp.observe_property("time-pos", "number", update_timeline_overlay)
    mp.observe_property("osd-width", "number", on_osd_width_change)
    mp.observe_property("osd-height", "number", on_osd_height_change)
    TimelineOverlay.observers_added = true
  end
end

local function register_bindings()
  add_user_binding("key_toggle_mark", "c", "video_cutter_toggle_mark", toggle_mark)
  add_user_binding("key_cancel_job", "x", "video_cutter_cancel_job", cancel_current_or_last_job)
  add_user_binding("key_toggle_audio", "a", "video_cutter_toggle_audio", toggle_audio)
  add_user_binding("key_toggle_subs", "Ctrl+s", "video_cutter_toggle_subs", toggle_subs)
  add_user_binding("key_toggle_gif", "g", "video_cutter_toggle_gif", toggle_gif_mode)
  add_user_binding("key_toggle_lossless", "Ctrl+l", "video_cutter_toggle_lossless", toggle_lossless)
  add_user_binding("key_toggle_hardware", "H", "video_cutter_toggle_hardware", toggle_hardware)
  add_user_binding("key_toggle_audio_only", "Shift+a", "video_cutter_toggle_audio_only", toggle_audio_only)
  add_user_binding("key_clear_mark", "C", "video_cutter_clear_mark", clear_mark)
  add_user_binding("key_show_state", "i", "video_cutter_show_state", show_state)
  add_user_binding("key_show_hud", "h", "video_cutter_show_hud", show_status_hud)
  add_user_binding("key_show_help", "?", "video_cutter_show_help", show_help)
  add_user_binding("key_cycle_preset", "p", "video_cutter_cycle_preset", cycle_preset)
  add_user_binding("key_toggle_merge", "Ctrl+m", "video_cutter_toggle_merge", toggle_merge_mode)
  add_user_binding("key_toggle_queue", "Ctrl+q", "video_cutter_toggle_queue", toggle_queue_mode)
  add_user_binding("key_toggle_timeline", "t", "video_cutter_toggle_timeline", toggle_timeline_overlay)
  add_user_binding("key_settings_menu", "Shift+m", "video_cutter_settings_menu", toggle_settings_menu)

  add_user_binding("key_set_start", "Shift+s", "video_cutter_set_start", set_start)
  add_user_binding("key_set_end", "Shift+e", "video_cutter_set_end", set_end)
  add_user_binding("key_execute_cut", "Shift+x", "video_cutter_execute_cut", execute_cut)
  add_user_binding("key_render_queue", "r", "video_cutter_render_queue", render_queue)
  add_user_binding("key_undo", "u", "video_cutter_undo", undo_last)
  add_user_binding("key_open_output", "o", "video_cutter_open_output", open_last_output)
  add_user_binding("key_preview_segment", "Shift+p", "video_cutter_preview_segment", preview_segment)
  -- Optional quick-cut keys (default unbound; user assigns keys in config).
  add_user_binding("key_quick_cut_last", "", "video_cutter_quick_cut_last", function()
    quick_cut_last(o.quick_cut_seconds or 30)
  end)
  add_user_binding("key_quick_cut_30", "", "video_cutter_quick_cut_30", function()
    quick_cut_last(30)
  end)
  add_user_binding("key_quick_cut_60", "", "video_cutter_quick_cut_60", function()
    quick_cut_last(60)
  end)

  add_user_binding("key_save_settings", "Ctrl+Alt+s", "video_cutter_save_settings", save_settings)
  add_user_binding("key_load_settings", "Ctrl+Alt+l", "video_cutter_load_settings", function()
    load_settings(true)
  end)
  add_user_binding("key_export_cuts", "Ctrl+Alt+e", "video_cutter_export_cuts", export_cuts)
end

-- ============================================================================
-- FORWARD DECLARATIONS / TABLE POPULATION
-- ============================================================================

local function initialize()
  math.randomseed(os.time())
  Config.init()
  register_bindings()

  mp.register_event("file-loaded", on_file_loaded)
  mp.register_event("end-file", cleanup)

  init_timeline_overlay()
  check_all_dependencies()
  load_settings()

  -- Enforce compatibility mode on startup to guarantee MP4/H264/AAC output
  -- unless the user explicitly disables it in their config file. The same
  -- invariant is re-applied by every config setter and after load_settings.
  enforce_compatibility_mode()

  local hw = HardwareAccelDetected or "software"
  osd(string.format("Video Cutter v%s | Hardware: %s | Press '?' for help", SCRIPT_VERSION, hw), 3)
  Logger.info(
    string.format("Video cutter v%s initialized - Hardware: %s - Press '?' for help, 'h' for HUD", SCRIPT_VERSION, hw)
  )
end

initialize()
