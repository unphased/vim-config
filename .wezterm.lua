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
-- config.color_scheme = 'Tomorrow Night Eighties'

local TMEcolor = wezterm.color.get_builtin_schemes()['Tomorrow Night Eighties'];
TMEcolor.ansi[1] = '#333333'
TMEcolor.brights[1] = '#3d3d3d'

config.color_schemes = {
  ['TME'] = TMEcolor,
}
config.color_scheme = 'TME';

config.keys = {
  { key = 'F11'      , action = wezterm.action.ToggleFullScreen, }                                                 ,
  { key = 'Backspace', mods = 'CTRL' , action = wezterm.action.SendString '\x1b\x7f' }   ,
  { key = '=' , mods = 'CTRL' , action = wezterm.action.DisableDefaultAssignment },
  { key = '-' , mods = 'CTRL' , action = wezterm.action.DisableDefaultAssignment },
  { key = '=' , mods = 'ALT'  , action = wezterm.action.IncreaseFontSize },
  { key = '-' , mods = 'ALT'  , action = wezterm.action.DecreaseFontSize },
}

config.hide_tab_bar_if_only_one_tab = true
config.font_size = 9.0
config.underline_thickness = 1.5

config.window_background_opacity = 0.3
config.win32_system_backdrop = 'Acrylic'

config.font = wezterm.font('RobotoMono Nerd Font Mono')

config.background = {
  -- This is the deepest/back-most layer. It will be rendered first
  {
    source = {
      Gradient={
        preset="Warm",
        orientation = { Linear = { angle = -45.0 } },
      }
    },
  }
}

-- and finally, return the configuration to wezterm
return config
