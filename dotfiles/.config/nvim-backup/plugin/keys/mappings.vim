" Leader
let mapleader="\\"
let maplocalleader = "<space>"

" Map{{{
map <C-h> <C-w>h
map <C-j> <C-w>j
map <C-k> <C-w>k
map <C-l> <C-w>l
map ge :b #<CR>
"map <leader>cp :Pickachu<CR>
let g:floaterm_keymap_toggle = '<F1>'
let g:floaterm_keymap_next   = '<F2>'
let g:floaterm_keymap_prev   = '<F3>'
let g:floaterm_keymap_new    = '<F4>'
"map <C-p> :Files<CR>
"map <C-b> :Buffers<CR>
"map <C-f> :RG<CR>
"map <leader>fr :FloatermNew ranger<CR>
nnoremap <leader><F5> :VimspectorReset<CR>
lnoremap <silent> <leader><F9> :call vimspector#ToggleBreakpoint()<CR>
"}}}

" Normal{{{
nnoremap <leader>ev : vsplit $MYVIMRC<CR>
nnoremap <leader>sv :source $MYVIMRC<CR>
nnoremap <space><space> za
nnoremap <silent> <C-w>> :exe "vertical resize " . (winwidth(0) * 3/2)<CR>
nnoremap <silent> <C-w>> :exe "vertical resize " . (winwidth(0) * 3/2)<CR>
nnoremap <silent> <C-w>< :exe "vertical resize " . (winwidth(0) * 2/3)<CR>
nnoremap <silent> <C-w>+ :exe "resize " . (winheight(0) * 3/2)<CR>
nnoremap <silent> <C-w>- :exe "resize " . (winheight(0) * 2/3)<CR>
"let g:ctrlp_map = '<c-p>'
"nnoremap <C-f> :Ag<SPACE>
"let g:ctrlp_map = '<c-p>'
"nnoremap <silent> <c-p> :<c-u>CtrlP<CR>
"nnoremap <silent> <c-b> :<c-u>CtrlPBuffer<CR>
"nnoremap <leader>ff fw :Rg<CR>
"nnoremap <leader><F5> VimspectorStop \| :VimspectorReset<CR>
"nnoremap <silent> <leader><F5> :VimspectorReset<CR>
"}}}

" Insert{{{
"}}}

" Visual{{{
"vmap <leader>te "+y
"}}}

" Modules{{{
" Esc{{{
nmap <c-c> <esc>
imap <c-c> <esc>
vmap <c-c> <esc>
omap <c-c> <esc>
nnoremap <c-c> :noh <CR>

"}}}

" WhichKey{{{
nnoremap <silent> <space>  :<c-u>WhichKey       '<space>' <CR>
vnoremap <silent> <space>  :<c-u>WhichKeyVisual  '<space>' <CR>
nnoremap <silent> <leader> :call GetBuffers() <bar> WhichKey '\' <CR>
vnoremap <silent> <leader> :<c-u>WhichKeyVisual  '\'<CR>
"}}}

" Coc{{{
" Normal{{{
" Goto
nmap <silent> gd <Plug>(coc-definition)
nmap <silent> gr <Plug>(coc-references)
nmap <silent> gy <Plug>(coc-type-definition)
nmap <silent> gi <Plug>(coc-implementation)
nmap <silent> gr <Plug>(coc-references)
nmap <silent> <TAB> <Plug>(coc-range-select)
"nmap <leader>rn <Plug>(coc-rename)
" Navigate diagnostics
"nnoremap <silent> <space>a  :<C-u>CocList diagnostics<cr>
"nnoremap <silent> <space>e  :<C-u>CocList extensions<cr>
"nnoremap <silent> <space>c  :<C-u>CocList commands<cr>
"nnoremap <silent> <space>o  :<C-u>CocList outline<cr>
"nnoremap <silent> <space>s  :<C-u>CocList -I symbols<cr>
"nnoremap <silent> <space>j  :<C-u>CocNext<CR>
"nnoremap <silent> <space>k  :<C-u>CocPrev<CR>
"nnoremap <silent> <space>p  :<C-u>CocListResume<CR>
"nnoremap <silent> <space>S  :<C-u>OR<CR>
nnoremap <silent> [g <Plug>(coc-diagnostic-prev)
nnoremap <silent> ]g <Plug>(coc-diagnostic-next)
"}}}

" Visual{{{
xmap af             <Plug>(coc-funcobj-a)
xmap if             <Plug>(coc-funcobj-i)
xmap af             <Plug>(coc-funcobj-a)

xmap <silent> <TAB> <Plug>(coc-range-select)
"xmap <leader>a  <Plug>(coc-codeaction-selected)
"}}}

" Omap {{{
omap if <Plug>(coc-funcobj-i)
omap af <Plug>(coc-funcobj-a)"}}}
"}}}}}}

" vim:foldmethod=marker:foldlevel=0
