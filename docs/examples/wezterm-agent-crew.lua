-- agent-crew fleet status in wezterm's right status bar.
-- Install: copy to ~/.config/wezterm/agent-crew.lua, then in wezterm.lua
-- (before `return config`):  require('agent-crew').apply(config)
--
-- Shows `⚓lab 2▶ 1⚑` = fleet, crewmates in flight, rooms pending on the
-- captain; ` WATCH!` appears when crew flies unwatched. Polls
-- bin/ac-statusline.sh (file reads only) every 5s.

local wezterm = require 'wezterm'
local M = {}

local HOME = os.getenv 'HOME'
local FLEET_HOME = HOME .. '/Work/ac-homes/lab'
local STATUSLINE = HOME .. '/Work/agent-crew/bin/ac-statusline.sh'

function M.apply(config)
  -- The right status lives in the tab bar: it must be visible even with a
  -- single tab (herdr users run everything in one tab). The retro bar is
  -- a slim one-liner that stays out of the way.
  config.hide_tab_bar_if_only_one_tab = false
  config.use_fancy_tab_bar = false
  config.status_update_interval = 5000
  wezterm.on('update-status', function(window, _)
    local ok, stdout = wezterm.run_child_process {
      '/bin/bash', '-c',
      'AC_HOME=' .. FLEET_HOME .. ' ' .. STATUSLINE .. ' 2>/dev/null',
    }
    if not ok or not stdout or stdout == '' then
      window:set_right_status ''
      return
    end
    local text = stdout:gsub('%s+$', '')
    local fg = text:find 'WATCH!' and '#e05d44' or '#e8a33d'
    window:set_right_status(wezterm.format {
      { Foreground = { Color = fg } },
      { Text = text .. '  ' },
    })
  end)
end

return M
