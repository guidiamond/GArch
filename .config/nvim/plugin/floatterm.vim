" Auto open ranger when no file is selected
autocmd StdinReadPre * let s:std_in=1
autocmd VimEnter * if argc() == 1 && isdirectory(argv()[0]) && !exists("s:std_in") | exe 'bd' | exe 'FloatermNew ranger' | endif

" Opening strategy for `COMMIT_EDITMSG` window by running `git commit` in
" the floaterm window. Only works in neovim. The value can be
" 'floaterm'(open gitcommit in the floaterm window), 'split'(recommended),
" 'vsplit', 'tabe'.
let g:floaterm_gitcommit='floaterm'

" Layout
let g:floaterm_width=0.9
let g:floaterm_height=0.7
let g:floaterm_wintitle=0

" Whether to close floaterm window once a job gets finished.
" 0 - Always do NOT close floaterm window.
" 1 - Close window only if the job exits normally
" 2 - Always close floaterm window.
let g:floaterm_autoclose=1

