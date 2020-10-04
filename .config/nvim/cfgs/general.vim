" Cmds
autocmd BufWritePost ~/.Xresources !xrdb % 
"autocmd BufWritePost *.tsx call FixReactScssModules()
autocmd FileType * setlocal formatoptions-=c formatoptions-=r formatoptions-=o " Disable automatic commenting

set path+=** " Paths to look for when doing searches
set hidden " Dont ask for ! when changing buffer
let g:python3_host_prog = expand('~/.virtualenv/nvim/bin/python')
let g:vim_jsx_pretty_colorful_config = 1 " default 0

"}}}
" Fold{{{
set foldenable
set foldlevelstart=10
set foldnestmax=10
set foldmethod=syntax
"}}}
" Functions {{{
function FixReactScssModules()
  silent! execute '%s/\(className=\)"\(.*\)"/\1{scss["\2"]}/g'
  silent! execute '%s/\(id=\)"\(.*\)"/\1{style["\2"]}/g'
endfunction

"}}}
" Tabs and spaces{{{
set softtabstop=2 " <Tab> indent (should be equal to shiftwidth)
set tabstop=2
set shiftwidth=2 " Size of << >> and autoindents
set expandtab " Convert tabs to spaces
set noshiftround " Dont convert odd spacing to nearest shiftwidth
"}}}
" Search{{{
set incsearch " Match words while writing
set ignorecase " Include matching uppercase words with lowercase search term
set smartcase " Include only uppercase words with uppercase search term
"""""""""}}}
" UI{{{
set wildmenu " Completion for Command mode
set wildignore+=**/node_modules/**,.pyc,.swp
set noerrorbells " Disable beep on error
set visualbell " Flash on error
set number " Add line numbers
"set title " Add terminal title
set relativenumber " Line number relative to your current line
set cursorline " Highlight current line
set showmatch " Lightline matching bracket
set wrap " Wrap text beyound screen length
set ttyfast " Faster characters in terminal
set mouse=a " Enable mouse
set scrolloff=5 " Number of lines to show when scrolling
set splitbelow splitright " Split directions
"}}}
" Styles{{{
syntax enable
filetype plugin on
"set t_Co=256 " Enable 256 color support
"set background=dark " or light if you prefer the light version
"colorscheme dracula
let g:one_allow_italics = 1 " I love italic for comments
colorscheme challenger_deep
"colorscheme onedark
set termguicolors

"hi CursorLine   cterm=NONE ctermbg=17 ctermfg=NONE "Currentline color
hi CursorLine   cterm=NONE ctermbg=NONE ctermfg=NONE guibg=NONE "Currentline color
hi NORMAL   ctermbg=None guibg=#282a36" Background color
hi LineNr cterm=NONE ctermfg=grey ctermbg=NONE guibg=NONE
" vim:foldmethod=marker:foldlevel=0
