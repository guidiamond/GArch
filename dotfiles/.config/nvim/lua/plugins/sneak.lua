local set = vim.g
local cmd = vim.cmd

-- Prompt icon:
set["sneak#prompt"] = "🔎 "

-- case insensitive sneak
set['sneak#label'] = 1

set['sneak#use_ic_scs'] = 1

-- Highlighting color
cmd [[ highlight Sneak guifg=black guibg=#00C7DF ctermfg=black ctermbg=cyan ]]
cmd [[ highlight SneakScope guifg=red guibg=yellow ctermfg=red ctermbg=yellow ]]
