local set = vim.g
local cmd = vim.cmd

cmd [[ highlight QuickScopePrimary guifg='#00C7DF' gui=underline ctermfg=155 cterm=underline ]]
cmd [[ highlight QuickScopeSecondary guifg='#afff5f' gui=underline ctermfg=81 cterm=underline ]]

-- Trigger a highlight in the appropriate direction when pressing these keys:
set.qs_highlight_on_keys = {'f', 'F', 't', 'T'}

-- Disable plugin on long lines:
-- vim.qs_max_chars=150
