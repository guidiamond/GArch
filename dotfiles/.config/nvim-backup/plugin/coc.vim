" Extension cfgs {{{

" Coc-css {{{
autocmd FileType scss setl iskeyword+=@-@
"}}}

" Coc-stylelintplus {{{
autocmd BufWritePost *.css,*.scss silent! execute CocAction('runCommand','stylelintplus.applyAutoFixes')
"}}}


"Coc-explorer {{{
let g:coc_explorer_global_presets = {
\   '.vim': {
\     'root-uri': '~/.vim',
\   },
\   'tab': {
\     'position': 'tab',
\     'quit-on-open': v:true,
\   },
\   'floating': {
\     'position': 'floating',
\     'open-action-strategy': 'sourceWindow',
\   },
\   'floatingTop': {
\     'position': 'floating',
\     'floating-position': 'center-top',
\     'open-action-strategy': 'sourceWindow',
\   },
\   'floatingLeftside': {
\     'position': 'floating',
\     'floating-position': 'left-center',
\     'floating-width': 50,
\     'open-action-strategy': 'sourceWindow',
\   },
\   'floatingRightside': {
\     'position': 'floating',
\     'floating-position': 'right-center',
\     'floating-width': 50,
\     'open-action-strategy': 'sourceWindow',
\   },
\   'simplify': {
\     'file-child-template': '[selection | clip | 1] [indent][icon | 1] [filename omitCenter 1]'
\   }
\ }

" Autoclose coc-explorer if it's the last buffer available
autocmd BufEnter * if (winnr("$") == 1 && &filetype == 'coc-explorer') | q | endif


"}}}

"}}}

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
let g:coc_snippet_next = '<tab>'

" Use <c-space> to trigger completion.
if has('nvim')
  inoremap <silent><expr> <c-space> coc#refresh()
else
  inoremap <silent><expr> <c-@> coc#refresh()
endif

"Use <cr> to confirm completion
 if exists('*complete_info')
  inoremap <expr> <cr> complete_info()["selected"] != "-1" ? "\<C-y>" : "\<C-g>u\<CR>"
else
  imap <expr> <cr> pumvisible() ? "\<C-y>" : "\<C-g>u\<CR>"
endif

nmap <silent> K :call <SID>show_documentation()<CR>
"}}}

" Styling{{{
" hi! CocErrorSign guifg=#ffffff guibg=#ffffff
" hi! CocErrorSign guifg=#353b45
" hi CocErrorSign  ctermfg=Black guifg=#000000
" hi! CocInfoSign guibg=#353b45
" hi! CocWarningSign guifg=#d1cd66
" highlight clear SignColumn
"}}}

" vim:foldmethod=marker:foldlevel=0
