let g:polyglot_disabled = ['css', 'scss', 'typescript']
source ~/.config/nvim/cfgs/plugins.vim
source ~/.config/nvim/cfgs/floatterm.vim
source ~/.config/nvim/cfgs/fzf.vim
source ~/.config/nvim/cfgs/vimspector.vim
source ~/.config/nvim/cfgs/signify.vim
source ~/.config/nvim/cfgs/quickscope.vim

source ~/.config/nvim/cfgs/sneak.vim
source ~/.config/nvim/cfgs/rainbow_parenthesis.vim
source ~/.config/nvim/cfgs/vim_which_key.vim
" Leader{{{
let mapleader="\\"
let maplocalleader = "<space>"
"}}}

" Map{{{
map <C-h> <C-w>h
map <C-j> <C-w>j
map <C-k> <C-w>k
map <C-l> <C-w>l
"map <leader>s <Plug>Sneak_s
"map <leader>S <Plug>Sneak_S
map gS <Plug>Sneak_,
map gs <Plug>Sneak_;
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

" Coc{{{
command! -nargs=0 Tsc :call CocAction('runCommand', 'tsserver.watchBuild')
command! -nargs=0 Rename :call CocAction('runCommand', 'workspace.renameCurrentFile')

function! s:show_documentation()
  if (index(['vim','help'], &filetype) >= 0)
    execute 'h '.expand('<cword>')
  else
    call CocAction('doHover')
  endif
endfunction
nmap <silent> K :call <SID>show_documentation()<CR>


set nobackup
set nowritebackup
set cmdheight=1 " Message spacing
set updatetime=300 " Coc update time
set shortmess+=c " Avoid hit-enter prompts
set signcolumn=yes

command! -nargs=0 Format  :call     CocAction('format')
command! -nargs=? Fold    :call     CocAction('fold', <f-args>)
command! -nargs=0 OR      :call     CocAction('runCommand', 'editor.action.organizeImport')
command! -nargs=0 FXSCSS  :call     FixReactScssModules()
command! -nargs=0 Prettier :CocCommand prettier.formatFile

autocmd CursorHold * silent call CocActionAsync('highlight')
autocmd BufWritePost *.tsx silent! execute CocAction('runCommand', 'eslint.executeAutofix')


"let g:NERDCustomDelimiters = { 'typescript.tsx': { 'left': '{/* ', 'right': ' */}' } }

augroup filetypes
    autocmd!
    au BufNewFile,BufRead *.ts setlocal filetype=typescript
    au BufNewFile,BufRead *.tsx setlocal filetype=typescript.tsx
    au BufNewFile,BufRead *.jsx setlocal filetype=javascript.jsx
    au BufNewFile,BufRead *.scss,*.css setlocal filetype=scss
augroup end

augroup mygroup
  autocmd!
  " Setup formatexpr specified filetype(s).
  autocmd FileType typescript,json setl formatexpr=CocAction('formatSelected')
  " Update signature help on jump placeholder.
  autocmd User CocJumpPlaceholder call CocActionAsync('showSignatureHelp')
augroup end
"}}}
"ﭥﭥ襁勉喝卑壘喇
let g:Powerline_symbols = 'fancy'
highlight clear SignColumn
hi! CocErrorSign guifg=#d1666a
hi! CocInfoSign guibg=#353b45
hi! CocWarningSign guifg=#d1cd66
if exists('+termguicolors')
  let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
  let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"
  set termguicolors
endif

"autocmd FileType json syntax match Comment +\/\/.\+$+
autocmd BufRead,BufNewFile tsconfig.json set filetype=jsonc
" autocmd BufRead,BufNewFile tsconfig.json set syntax=json
autocmd syntax json syntax match Comment +\/\/.\+$+

function MyNerdToggle()
    if &filetype == 'nerdtree'
        :NERDTreeToggle
    else
        :NERDTreeFind
    endif
endfunction
map ge :b #<CR>
map <C-n> :call MyNerdToggle()<CR>
let NERDTreeMouseMode=2
let NERDTreeMinimalUI = 1
let NERDTreeDirArrows = 1
let g:NERDTreeHighlightCursorline = 1
let g:NERDTreeQuitOnOpen=1
let NERDTreeShowHidden=1
let NERDTreeAutoDeleteBuffer = 1



"augroup MouseInNERDTreeOnly
    "autocmd!
    "autocmd BufEnter NERD_tree_* set mouse=a
    "autocmd BufLeave NERD_tree_* set mouse=
"augroup END
"set mouse=

"let g:AutoPairs= {'(':')', '[':']', '{':'}',"'":"'",'"':'"', '`':'`'}
"set ttymouse=sgr
" vim:foldmethod=marker:foldlevel=0
let g:mkdp_auto_start = 1
