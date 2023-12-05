-- require('copilot').setup({})
--

local set = vim.g

set.copilot_no_tab_map = true
set.copilot_assume_mapped = true
set.copilot_tab_fallback = ""
vim.api.nvim_set_keymap('i', '<C-e>', 'copilot#Accept("<CR>")', { expr = true, noremap = true, silent = true })
