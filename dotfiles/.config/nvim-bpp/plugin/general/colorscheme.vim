syntax enable
filetype plugin on

let g:one_allow_italics = 1
"colorscheme spaceduck
colorscheme onehalfdark
set termguicolors

" Spaceduck fixes
" Comment was too dark to see
" hi Comment guifg=#4b5595
" Visual selection was too light to see
" hi Visual guibg=#30315f
" Alternate Visual selection color
" hi Visual guibg=#203d1f

"hi CursorLine   cterm=NONE ctermbg=17 ctermfg=NONE "Currentline color
" hi CursorLine   cterm=NONE ctermbg=NONE ctermfg=NONE guibg=NONE "Currentline color
" hi NORMAL   ctermbg=None guibg=#282a36" Background color
" hi LineNr cterm=NONE ctermfg=grey ctermbg=NONE guibg=NONE

if exists('+termguicolors')
  let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
  let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"
  set termguicolors
endif

" vim:foldmethod=marker:foldlevel=0
" set t_Co=256 " Enable 256 color support
"set background=dark " or light if you prefer the light version
