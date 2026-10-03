-- E2E driver for video-segment-cutter.lua.
-- VCT_SCENARIO=cut|probe-c|ytdl-cut   VCT_QUIT=seconds (default 7)
-- cut:     set mark @0.5s, cut @2.5s (expect an output file)
-- probe-c: press c twice (expect NO output when the binding is disabled)
-- ytdl-cut: as cut, but path is set to VCT_YTDL_URL first (tests the
--           script's ytdl:// handling without mpv's ytdl_hook, which
--           deliberately no-ops on direct media links)
local scenario = os.getenv("VCT_SCENARIO") or "cut"
local quit_after = tonumber(os.getenv("VCT_QUIT")) or 7
local acted = false
mp.register_event("file-loaded", function()
  if acted then return end
  acted = true
  mp.command("set pause no")
  if scenario == "ytdl-cut" then
    mp.set_property("path", os.getenv("VCT_YTDL_URL") or "")
  end
  if scenario == "cut" or scenario == "ytdl-cut" then
    mp.add_timeout(1.0, function() mp.command("seek 0.5 absolute"); mp.command("keypress c") end)
    mp.add_timeout(2.5, function() mp.command("seek 2.5 absolute"); mp.command("keypress c") end)
  else
    mp.add_timeout(1.0, function() mp.command("seek 0.5 absolute"); mp.command("keypress c") end)
    mp.add_timeout(3.0, function() mp.command("keypress c") end)
  end
  mp.add_timeout(quit_after, function() mp.command("quit") end)
end)