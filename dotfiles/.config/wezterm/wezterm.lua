local wezterm = require("wezterm")

--[[
-- This will hold the configuration.
-- The config builder may look like a regular lua table but it is really a special userdata type that knows how to log warnings or generate errors if you attempt to define an invalid configuration option.
--]]
local config = wezterm.config_builder()

config.default_cursor_style = "SteadyBar" -- SteadyBlock, BlinkingBlock, SteadyUnderline, BlinkingUnderline, SteadyBar, and BlinkingBar

-- config.color_scheme = "Catppuccin Mocha"
-- config.color_scheme = "Kanagawa (Gogh)"
-- config.color_scheme = "OneHalfDark"
config.color_scheme = "Dracula"
config.font = wezterm.font({ family = "SauceCodePro Nerd Font", weight = 500 })

config.window_close_confirmation = "NeverPrompt" -- NeverPrompt, AlwaysPrompt

config.max_fps = 75
config.enable_tab_bar = false
config.font_size = 12
config.term = "wezterm"
config.window_background_opacity = 0.8

config.scrollback_lines = 50000

-- Copy on mouse select (to both clipboard and primary selection)
config.selection_word_boundary = " \t\n{}[]()\"'`,;:@"
config.mouse_bindings = {
	{
		event = { Up = { streak = 1, button = "Left" } },
		mods = "NONE",
		action = wezterm.action.CompleteSelectionOrOpenLinkAtMouseCursor("ClipboardAndPrimarySelection"),
	},
}

config.keys = {
	{
		mods = "ALT",
		key = "c",
		action = wezterm.action.CopyTo("ClipboardAndPrimarySelection"),
	},
	{
		mods = "ALT",
		key = "v",
		action = wezterm.action.PasteFrom("Clipboard"),
	},
}

return config
