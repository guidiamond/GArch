local set = vim.g

local opts = {
	noremap = true, -- Non recursive mapping (will only change the specific keymap)
	silent = true,
}

set.mapleader = "\\"
set.maplocalleader = "<space>"

local keymap = vim.api.nvim_set_keymap

-- Modes:
--   map  (Normal, Visual, Select, Operator-pending) = "", -- empty string
--   nmap (Normal)                                   = "n",
--   vmap (Visual, Select)                           = "v",
--   smap (Select)                                   = "s",
--   xmap (Visual)                                   = "x",
--   omap (Operator-pending) - omap                  = "o",
--   map! (Insert, Command Line)                     = "!",
--   imap (Insert)                                   = "i",
--   lmap (Insert, Command-line, Lang-Arg)           = "l",
--   cmap (Command-line)                             = "c",
--   tmap (Terminal)                                 = "t"

-- Better window navigation
keymap("n", "<C-h>", "<C-w>h", opts)
keymap("n", "<C-j>", "<C-w>j", opts)
keymap("n", "<C-k>", "<C-w>k", opts)
keymap("n", "<C-l>", "<C-w>l", opts)

keymap("n", "ge", ":b #<CR>", opts) -- Switch to last buffer
keymap("n", "J", "mzJ`z", opts) -- Don't move cursor when (J)oining line from above

-- Allows moving selected chunks of code
keymap("v", "J", ":m '>+1<CR>gv=gv", opts)
keymap("v", "K", ":m '<-2<CR>gv=gv", opts)

-- Half page always show cursor in the middle
keymap("n", "<C-d>", "<C-d>zz", opts)
keymap("n", "<C-u>", "<C-u>zz", opts)

-- Don't overwrite yank register
keymap("x", "P", [["_dP]], opts)

keymap("n", "gb", ":lua require'gitsigns'.blame_line{full=false}<CR>", opts)
keymap("n", "gB", ":lua require'gitsigns'.blame_line{full=true}<CR>", opts)
keymap("n", "gh", ":Gitsigns preview_hunk<CR>", opts)
keymap("n", "gh", ":Gitsigns preview_hunk<CR>", opts)

-- Resize splits
keymap("n", "<C-w>>", ":vertical resize +2", opts)
keymap("n", "<C-w><", ":vertical resize -2", opts)
keymap("n", "<C-w>+", ":resize +2", opts)
keymap("n", "<C-w>-", ":resize -2", opts)

-- Esc has the same function as Ctrl + C
keymap("n", "<C-c>", "<esc>", {noremap = false})
keymap("i", "<C-c>", "<esc>", {noremap = false})
keymap("v", "<C-c>", "<esc>", {noremap = false})
keymap("o", "<C-c>", "<esc>", {noremap = false})
keymap("n", "<C-c>", ":noh <CR>", opts) -- Stop highlighting
