autocmd BufWritePost ~/.Xresources !xrdb % 
autocmd FileType * setlocal formatoptions-=c formatoptions-=r formatoptions-=o " Disable automatic commenting

set path+=** " Paths to look for when doing searches
set hidden " Dont ask for ! when changing buffer
let g:python3_host_prog = expand('~/.virtualenv/nvim/bin/python')
let g:vim_jsx_pretty_colorful_config = 1 " default 0
