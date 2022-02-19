let $FZF_DEFAULT_OPTS = '--info=inline'
let $FZF_DEFAULT_COMMAND="rg --files --hidden"

let g:fzf_history_dir = '~/.cache/fzf/history'
let g:fzf_tags_command = 'ctags -R'

let g:fzf_action = {
      \ 'ctrl-t': 'tab split',
      \ 'ctrl-x': 'split',
      \ 'ctrl-v': 'vsplit'
      \ }

"" Customize fzf colors to match your color scheme
let g:fzf_colors =
\ { 'fg':      ['fg', 'Normal'],
  \ 'hl':      ['fg', 'Comment'],
  \ 'fg+':     ['fg', 'CursorLine', 'CursorColumn', 'Normal'],
  \ 'bg+':     ['bg', 'CursorLine', 'CursorColumn'],
  \ 'hl+':     ['fg', 'Statement'],
  \ 'info':    ['fg', 'PreProc'],
  \ 'border':  ['fg', 'Ignore'],
  \ 'prompt':  ['fg', 'Conditional'],
  \ 'pointer': ['fg', 'Exception'],
  \ 'marker':  ['fg', 'Keyword'],
  \ 'spinner': ['fg', 'Label'],
  \ 'header':  ['fg', 'Comment'] }

"" Ripgrep advanced
function! RipgrepFzf(query, fullscreen)
  let command_fmt = join([
        \ 'rg',
        \ '--column',
        \ '--line-number',
        \ '--no-heading',
        \ '--hidden -g "!{yarn.lock}"',
        \ '--color=always',
        \ '--smart-case %s || true'
        \ ])
  let initial_command = printf(command_fmt, shellescape(a:query))
  let reload_command = printf(command_fmt, '{q}')

  let spec = {
        \ 'window': {
          \ 'width': 0.8,
          \ 'height': 0.8,
          \ 'yoffset': 0.5,
          \ 'xoffset': 0.5,
          \ 'highlight': 'Todo',
          \ 'border': 'sharp'
        \ },
        \ 'options': [
          \ '--layout=reverse',
          \ '--info=inline',
          \ '--phony',
          \ '--query', a:query,
          \ '--bind',
          \ 'change:reload:'.reload_command
        \ ]}
  call fzf#vim#grep(initial_command, 1, fzf#vim#with_preview(spec), a:fullscreen)
endfunction

"" Get text in files with Rg
      " \ call fzf#vim#grep(
      " \   'rg --column --line-number --no-heading --color=always --smart-case '.shellescape(<q-args>), 1,
      " \   fzf#vim#with_preview({'window':{'width': 0.8, 'height': 0.8,'yoffset':0.5,'xoffset': 0.5, 'highlight': 'Todo', 'border': 'sharp' },'options': ['--layout=reverse', '--info=inline']}), <bang>0)
"
command! -nargs=* -bang RG call RipgrepFzf(<q-args>, <bang>0)
command! -bang -nargs=? -complete=dir Files call fzf#vim#files(<q-args>, {
      \ 'window': {
        \ 'width': 0.98,
        \ 'height': 0.35,
        \ 'yoffset': 1.0,
        \ 'border': 'top'
      \ },
      \ 'options': [
      \ '--info=inline'
      \ ]},
      \ <bang>0)

"" Git grep
command! -bang -nargs=* GGrep
      \ call fzf#vim#grep(
      \   'git grep --line-number '.shellescape(<q-args>), 0,
      \   fzf#vim#with_preview({'dir': systemlist('git rev-parse --show-toplevel')[0]}), <bang>0)
