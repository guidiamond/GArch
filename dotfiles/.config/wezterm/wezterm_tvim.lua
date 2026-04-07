-- [[
-- Use this config together with tvim to get no padding inside vim
-- This is a workaround for the issue where wezterm does not support setting configs dynamically
-- This works in combination with the tvim alias created on ~/.scripts/alias.sh
--
-- ]]
local config = require("./wezterm")

config.window_padding = {
	left = 0,
	right = 0,
	top = 0,
	bottom = 0,
}

return config
