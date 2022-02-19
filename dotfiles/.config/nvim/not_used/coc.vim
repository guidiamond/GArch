" Extensions{{{
let g:coc_global_extensions = [
  \ 'coc-snippets',
  \ 'coc-emmet',
  \ 'coc-css',
  \ 'coc-pairs',
  \ 'coc-tsserver',
  \ 'coc-eslint', 
  " \ 'coc-prettier', 
  \ 'coc-styled-components',
  \ 'coc-json', 
  \ 'coc-clangd', 
  \ ]
"}}}
" Functions{{{
function! s:show_documentation()
  if (index(['vim','help'], &filetype) >= 0)
    execute 'h '.expand('<cword>')
  else
    call CocAction('doHover')
  endif
endfunction

function! s:check_back_space() abort
  let col = col('.') - 1
  return !col || getline('.')[col - 1]  =~# '\s'
endfunction
"}}}
" Normal keybinds{{{
" Goto
nmap <silent> gd <Plug>(coc-definition)
nmap <silent> gr <Plug>(coc-references)
nmap <silent> gy <Plug>(coc-type-definition)
nmap <silent> gi <Plug>(coc-implementation)
nmap <silent> gr <Plug>(coc-references)
nmap <silent> <TAB> <Plug>(coc-range-select)
nmap <leader>rn <Plug>(coc-rename)
" Navigate diagnostics
nnoremap <silent> <space>a  :<C-u>CocList diagnostics<cr>
nnoremap <silent> <space>e  :<C-u>CocList extensions<cr>
nnoremap <silent> <space>c  :<C-u>CocList commands<cr>
nnoremap <silent> <space>o  :<C-u>CocList outline<cr>
nnoremap <silent> <space>s  :<C-u>CocList -I symbols<cr>
nnoremap <silent> <space>j  :<C-u>CocNext<CR>
nnoremap <silent> <space>k  :<C-u>CocPrev<CR>
nnoremap <silent> <space>p  :<C-u>CocListResume<CR>
nnoremap <silent> [g <Plug>(coc-diagnostic-prev)
nnoremap <silent> ]g <Plug>(coc-diagnostic-next)
nmap <silent> K :call <SID>show_documentation()<CR>
" }}}
" Insert keybinds{{{
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
" Commands{{{
set nobackup
set nowritebackup
set cmdheight=2 " Message spacing
set updatetime=300 " Coc update time
set shortmess+=c " Avoid hit-enter prompts
set signcolumn=yes

command! -nargs=0 Format :call     CocAction('format')
command! -nargs=? Fold   :call     CocAction('fold', <f-args>)
command! -nargs=0 OR     :call     CocAction('runCommand', 'editor.action.organizeImport')
command! -nargs=0 Prettier :CocCommand prettier.formatFile

autocmd CursorHold * silent call CocActionAsync('highlight')
autocmd BufWritePost *.tsx silent! execute CocAction('runCommand', 'eslint.executeAutofix')
autocmd BufNewFile,BufRead *.scss,*.css set filetype=scss

augroup filetypes
    autocmd!
    au BufNewFile,BufRead *.ts setlocal filetype=typescript
    au BufNewFile,BufRead *.tsx setlocal filetype=typescript.tsx
    au BufNewFile,BufRead *.jsx setlocal filetype=javascript.jsx
augroup end

augroup mygroup
  autocmd!
  " Setup formatexpr specified filetype(s).
  autocmd FileType typescript,json setl formatexpr=CocAction('formatSelected')
  " Update signature help on jump placeholder.
  autocmd User CocJumpPlaceholder call CocActionAsync('showSignatureHelp')
augroup end
"}}}
" Visual keybinds{{{
xmap af             <Plug>(coc-funcobj-a)
xmap if             <Plug>(coc-funcobj-i)
xmap af             <Plug>(coc-funcobj-a)

xmap <silent> <TAB> <Plug>(coc-range-select)
xmap <leader>a  <Plug>(coc-codeaction-selected)
"}}}
" Omap keybinds (need operator){{{
omap if <Plug>(coc-funcobj-i)
omap af <Plug>(coc-funcobj-a)"}}}
"}}}
