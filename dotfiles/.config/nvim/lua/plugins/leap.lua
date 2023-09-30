local status_ok, leap = pcall(require, "leap")
if not status_ok then
  return
end

local set_hl = vim.api.nvim_set_hl

leap.add_default_mappings()

-- Default mappings:
-- s (forward) & S (backward) search
-- s<enter><enter> reapeats the previous search
-- gs or gS to search in multiple windows
-- s{char}<enter><enter> is the same as f{char};, but works over multiple lines.

set_hl(0, 'LeapBackdrop', { link = 'Comment' }) -- or some grey
set_hl(0, 'LeapMatch', {
  -- For light themes, set to 'black' or similar.
  fg = 'white', bold = true, nocombine = true,
})
-- Of course, specify some nicer shades instead of the default "red" and "blue".
set_hl(0, 'LeapLabelPrimary', {
  fg = 'red', bold = true, nocombine = true,
})
set_hl(0, 'LeapLabelSecondary', {
  fg = 'blue', bold = true, nocombine = true,
})
-- Try it without this setting first, you might find you don't even miss it.
leap.opts.highlight_unlabeled_phase_one_targets = true
