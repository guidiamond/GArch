local status_ok, leap = pcall(require, "leap")
if not status_ok then
	return
end

local set_hl = vim.api.nvim_set_hl

-- Set explicitly instead of via the deprecated `leap.add_default_mappings()`,
-- which still points at the removed `<Plug>(leap-forward-to)` /
-- `<Plug>(leap-backward-to)` keys and therefore silently does nothing.
vim.keymap.set({ "n", "x", "o" }, "s", "<Plug>(leap-forward)", { desc = "Leap forward to" })
vim.keymap.set({ "n", "x", "o" }, "S", "<Plug>(leap-backward)", { desc = "Leap backward to" })
vim.keymap.set({ "x", "o" }, "x", "<Plug>(leap-forward-till)", { desc = "Leap forward till" })
vim.keymap.set({ "x", "o" }, "X", "<Plug>(leap-backward-till)", { desc = "Leap backward till" })
vim.keymap.set({ "n", "x", "o" }, "gs", "<Plug>(leap-from-window)", { desc = "Leap from window" })

-- Mappings:
-- s (forward) & S (backward) search
-- s<enter><enter> reapeats the previous search
-- gs to search in multiple windows
-- s{char}<enter><enter> is the same as f{char};, but works over multiple lines.

set_hl(0, "LeapBackdrop", { link = "Comment" }) -- or some grey
set_hl(0, "LeapMatch", {
	-- For light themes, set to 'black' or similar.
	fg = "white",
	bold = true,
	nocombine = true,
})
-- Of course, specify some nicer shades instead of the default "red" and "blue".
set_hl(0, "LeapLabel", {
	fg = "red",
	bold = true,
	nocombine = true,
})
-- set_hl(0, "LeapLabelPrimary", {
-- 	fg = "red",
-- 	bold = true,
-- 	nocombine = true,
-- })
-- set_hl(0, "LeapLabelSecondary", {
-- 	fg = "blue",
-- 	bold = true,
-- 	nocombine = true,
-- })
-- Try it without this setting first, you might find you don't even miss it.
-- leap.opts.highlight_unlabeled_phase_one_targets = true
