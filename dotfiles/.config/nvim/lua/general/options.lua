-- vim.g
local global_vars = {
  python3_host_prog = vim.fn.expand('~/.virtualenv/nvim/bin/python')
}
for k, v in pairs(global_vars) do
  vim.g[k] = v
end

-- vim.api.nvim_set_option
local sets = {
  hidden = true, -- Dont ask for ! when changing buffer
}

for k, v in pairs(sets) do
  vim.api.nvim_set_option(k, v)
end
vim.api.nvim_get_option('path')

-- vim.opts
local options = {
  swapfile = false, -- creates a swapfile
  backup = false,

  termguicolors = true, -- set term gui colors (most terminals support this)
  -- Search
  incsearch=true,  -- Match words while writing
  ignorecase=true, -- Include matching uppercase words with lowercase search term
  smartcase=true,  -- Include only uppercase words with uppercase search term
  -- Spacing
  softtabstop=2,    -- <Tab> indent (should be equal to shiftwidth)
  tabstop=2,
  shiftwidth=2,     -- Size of << >> and autoindents
  expandtab=true,   -- Convert tabs to spaces
  shiftround=false, -- Dont convert odd spacing to nearest shiftwidth

  -- Fold
  foldenable=true,
  foldlevelstart=10,
  foldnestmax=10,
  foldmethod='syntax',
  -- UI
  wildmenu=true, -- Completion for Command mode
  errorbells=false, -- Disable beep on error                           
  visualbell=true, -- Flash on error
  number=true, -- Add line numbers
  relativenumber=true, -- Line number relative to your current line
  cursorline=true, -- Highlight current line
  showmatch=true, -- Lightline matching bracket
  wrap=true, -- Wrap text beyound screen length
  ttyfast=true, -- Faster characters in terminal
  mouse='a', -- Enable mouse
  scrolloff=5, -- Number of lines to show when scrolling

  showtabline=2, -- Always Show bar at the top
  showmode=false, -- Disable mode at the bottom

  -- split_directions,
  splitbelow=true,
  splitright=true,
}

for k, v in pairs(options) do
  vim.opt[k] = v
end
vim.opt.wildignore:append{'**/node_modules/**', '.pyc', '.swp'}
