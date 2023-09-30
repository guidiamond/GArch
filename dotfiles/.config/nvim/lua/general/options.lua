local function set_cfg(options, cfg_type)
  for k, v in pairs(options) do
    vim[cfg_type][k] = v
  end
end

local options = {
  g = {
    python3_host_prog = vim.fn.expand('~/.virtualenv/nvim/bin/python')
  },
  opt = {
    swapfile = false, -- creates a swapfile
    backup = false,

    hidden = true, -- Dont ask for ! when changing buffer

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

    ---@diagnostic disable-next-line: deprecated (unpack shows as deprecated, but using table.unpack throws an error)
    wildignore={'**/node_modules/**', '.pyc', '.swp', unpack(vim.opt.wildignore)}
  }
}

for cfg_type, opt_list in pairs(options) do
  set_cfg(opt_list, cfg_type)
end
