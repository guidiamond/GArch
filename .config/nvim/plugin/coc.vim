" Config{{{

" Make a backup before overwriting a file.  Leave it around after the
" file has been successfully written.
set nobackup 
" Make a backup before overwriting a file.  The backup is removed after
" the file was successfully written, unless the 'backup' option is
" also on.
set nowritebackup 

set cmdheight=1 " Message spacing
set updatetime=300 " Coc update time
set shortmess+=c " Avoid hit-enter prompts
set signcolumn=yes

"}}}

" Cmds{{{
autocmd CursorHold * silent call CocActionAsync('highlight')
autocmd BufWritePost *.tsx silent! execute CocAction('runCommand', 'eslint.executeAutofix')

" augroup mygroup
"   autocmd!
"   " Setup formatexpr specified filetype(s).
"   au FileType typescript,json setl formatexpr=CocAction('formatSelected')
"   " Update signature help on jump placeholder.
"   au User CocJumpPlaceholder call CocActionAsync('showSignatureHelp')
" augroup end

command! -nargs=0 Tsc      :call     CocAction('runCommand', 'tsserver.watchBuild')
command! -nargs=0 Rename   :call     CocAction('runCommand', 'workspace.renameCurrentFile')
command! -nargs=0 Format   :call     CocAction('format')
command! -nargs=? Fold     :call     CocAction('fold', <f-args>)
command! -nargs=0 OR       :call     CocAction('runCommand', 'editor.action.organizeImport')
command! -nargs=0 Prettier :CocCommand prettier.formatFile

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

inoremap <silent><expr> <TAB>
      \ pumvisible() ? "\<C-n>" :
      \ <SID>check_back_space() ? "\<TAB>" :
      \ coc#refresh()
inoremap <expr><S-TAB> pumvisible() ? "\<C-p>" : "\<C-h>"
" Use <c-space> to trigger completion.
"Use <cr> to confirm completion
 if exists('*complete_info')
  inoremap <expr> <cr> complete_info()["selected"] != "-1" ? "\<C-y>" : "\<C-g>u\<CR>"
else
  imap <expr> <cr> pumvisible() ? "\<C-y>" : "\<C-g>u\<CR>"
endif

nmap <silent> K :call <SID>show_documentation()<CR>
"}}}

" Styling{{{
hi! CocErrorSign guifg=#d1666a
hi! CocInfoSign guibg=#353b45
hi! CocWarningSign guifg=#d1cd66
highlight clear SignColumn
"}}}

" vim:foldmethod=marker:foldlevel=0
