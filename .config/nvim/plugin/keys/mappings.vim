" Leader
let mapleader="\\"
let maplocalleader = "<space>"

" Map{{{
map <C-h> <C-w>h
map <C-j> <C-w>j
map <C-k> <C-w>k
map <C-l> <C-w>l
"map <leader>s <Plug>Sneak_s
"map <leader>S <Plug>Sneak_S
map gS <Plug>Sneak_,
map gs <Plug>Sneak_;
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
"nnoremap <leader>ev : vsplit $MYVIMRC<CR>
"nnoremap <leader>sv :source $MYVIMRC<CR>
nnoremap <space><space> za
nnoremap <silent> <C-w>> :exe "vertical resize " . (winwidth(0) * 3/2)<CR>
"nnoremap <leader><leader>   :bnext<CR>
"nnoremap <leader>\|   :bprevious<CR>

"nmap <Leader>1 <Plug>lightline#bufferline#go(1)
"nmap <Leader>2 <Plug>lightline#bufferline#go(2)
"nmap <Leader>3 <Plug>lightline#bufferline#go(3)
"nmap <Leader>4 <Plug>lightline#bufferline#go(4)
"nmap <Leader>5 <Plug>lightline#bufferline#go(5)
"nmap <Leader>6 <Plug>lightline#bufferline#go(6)
"nmap <Leader>7 <Plug>lightline#bufferline#go(7)
"nmap <Leader>8 <Plug>lightline#bufferline#go(8)
"nmap <Leader>9 <Plug>lightline#bufferline#go(9)
"nmap <Leader>0 <Plug>lightline#bufferline#go(10)
"nmap <Leader>1 <Plug>AirlineSelectTab1
"nmap <Leader>2 <Plug>AirlineSelectTab2
"nmap <Leader>3 <Plug>AirlineSelectTab3
"nmap <Leader>4 <Plug>AirlineSelectTab4
"nmap <Leader>5 <Plug>AirlineSelectTab5
"nmap <Leader>6 <Plug>AirlineSelectTab6
"nmap <Leader>7 <Plug>AirlineSelectTab7
"nmap <Leader>8 <Plug>AirlineSelectTab8
"nmap <Leader>9 <Plug>AirlineSelectTab9

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
nnoremap <silent> <space>  :<c-u>WhichKey        '<space>' <CR>
vnoremap <silent> <space>  :<c-u>WhichKeyVisual  '<space>' <CR>
nnoremap <silent> <leader> :<c-u>WhichKey        '\'<CR>
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

" Insert{{{
function! s:check_back_space() abort
  let col = col('.') - 1
  return !col || getline('.')[col - 1]  =~# '\s'
endfunction

" Tab and Shift tab for going forward/backwards on completion
inoremap <silent><expr> <TAB>
      \ pumvisible() ? "\<C-n>" :
      \ <SID>check_back_space() ? "\<TAB>" :
      \ coc#refresh()
inoremap <expr><S-TAB> pumvisible() ? "\<C-p>" : "\<C-h>"
" Use <c-space> to trigger completion.
inoremap <silent><expr> <c-space> coc#refresh()

 "Use <cr> to confirm completion
 if exists('*complete_info')
  inoremap <expr> <cr> complete_info()["selected"] != "-1" ? "\<C-y>" : "\<C-g>u\<CR>"
else
  imap <expr> <cr> pumvisible() ? "\<C-y>" : "\<C-g>u\<CR>"
endif
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
