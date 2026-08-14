local set = vim.opt

set.wildmenu=true -- Completion for Command mode
set.errorbells=false -- Disable beep on error
set.visualbell=true -- Flash on error
set.number=true -- Add line numbers
set.relativenumber=true -- Line number relative to your current line
set.cursorline=true -- Highlight current line
set.showmatch=true -- Lightline matching bracket
set.wrap=true -- Wrap text beyound screen length
set.ttyfast=true -- Faster characters in terminal
set.mouse='a' -- Enable mouse
set.scrolloff=5 -- Number of lines to show when scrolling

set.showtabline=2 -- Always Show bar at the top
set.showmode=false -- Disable mode at the bottom

-- Split directions
set.splitbelow=true
set.splitright=true

set.wildignore = set.wildignore + '**/node_modules/**' + '.pyc' , '.swp'

-- set.title -- Add terminal title
