-- Pull in the wezterm API
local wezterm = require 'wezterm'

local mux = wezterm.mux

-- implement fullscreen from start
wezterm.on('gui-startup', function(cmd)
  local tab, pane, window = mux.spawn_window(cmd or {})
  window:gui_window():toggle_fullscreen()
end)

-- This table will hold the configuration.
local config = {}

-- In newer versions of wezterm, use the config_builder which will
-- help provide clearer error messages
if wezterm.config_builder then
  config = wezterm.config_builder()
end

-- This is where you actually apply your config choices

-- For example, changing the color scheme:
config.color_scheme = 'Tomorrow Night Eighties'

config.keys = {
        {
            key = 'F11',
            action = wezterm.action.ToggleFullScreen,
        },
    }
	
config.hide_tab_bar_if_only_one_tab = true
config.font_size = 9.0
config.underline_thickness = 1.5

config.window_background_opacity = 0
config.win32_system_backdrop = 'Mica'

-- and finally, return the configuration to wezterm
return config
