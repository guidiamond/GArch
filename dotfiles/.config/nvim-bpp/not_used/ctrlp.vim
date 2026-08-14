 "The Silver Searcher
if executable('ag')
  set grepprg=ag\ --nogroup\ --nocolor

  let g:ctrlp_user_command = 'ag %s -l --nocolor --hidden -p ~/.config/nvim/.ignore -g ""'

  let g:ctrlp_use_caching = 0
endif
command! -nargs=+ -complete=file -bar Ag silent! grep! <args>|cwindow|redraw!

let g:ctrlp_root_markers = ['init.vim','.git','tsconfig.json','package.json']
let g:ctrlp_working_path_mode = 'ra'
let g:ctrlp_custom_ignore = {
      \ 'dir':  '\.git$\|\.yardoc\|node_modules\|log\|plugged\|tmp$',
      \ 'file': '\.so$\|\.dat$|\.DS_Store$'
      \ }

"if executable('rg')
  "" Use ag over grep
  "set grepprg=rg\ --color=never

  "" Use ag in CtrlP for listing files. Lightning fast and respects .gitignore
  ""let g:ctrlp_user_command = 'rg %s --files -color=never --hidden --ignore-file ~/.config/nvim/.ignore --glob ""'
  "let g:ctrlp_user_command = 'rg %s --files --hidden --color=never --glob ""'

  "" ag is fast eough that CtrlP doesn't need to cache
  "let g:ctrlp_use_caching = 0
"endif
