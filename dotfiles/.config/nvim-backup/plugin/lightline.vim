set showtabline=2 " Show  buffers
set noshowmode " disable mode at the bottom

" Enables the usage of vim-devicons to display a filetype icon for the buffer. Default is 0.
let g:lightline#bufferline#enable_devicons = 1

" let g:lightline#bufferline#filename_modifier = ":gs?index??" " Tab filename/path format
" " let g:lightline#bufferline#filename_modifier = :.:gs?src/modules/??:r:gs?index?? " Tab filename/path format

" let g:lightline#bufferline#shorten_path = 0 
let g:lightline#bufferline#show_number = 2
let g:lightline#bufferline#unicode_symbols = 1
let g:lightline#bufferline#number_map = {
      \ 0: '⁰', 1: '¹', 2: '²', 3: '³', 4: '⁴',
      \ 5: '⁵', 6: '⁶', 7: '⁷', 8: '⁸', 9: '⁹'
      \ }



let g:lightline_error_icons = {
      \ 'errorSign': "",
      \ 'warningSign': "",
      \ 'infoSign': "",
      \ 'hintSign': "",
      \ }

function! s:lightline_coc_diagnostic(kind, sign) abort
  let info = get(b:, 'coc_diagnostic_info', 0)
  if empty(info) || get(info, a:kind, 0) == 0
    return ''
  endif
  try
    let s = g:lightline_error_icons[a:sign . 'Sign']
  catch
    let s = ''
  endtry
  return printf('%s %d', s, info[a:kind])
endfunction

function! LightlineCocErrors() abort
  return s:lightline_coc_diagnostic('error', 'error')
endfunction

function! LightlineCocWarnings() abort
  return s:lightline_coc_diagnostic('warning', 'warning')
endfunction

function! LightlineCocInfos() abort
  return s:lightline_coc_diagnostic('information', 'info')
endfunction

function! LightlineCocHints() abort
  return s:lightline_coc_diagnostic('hints', 'hint')
endfunction
\ }

autocmd User CocDiagnosticChange call lightline#update()

let g:lightline = {
      \ 'colorscheme': 'molokai',
      \ 'tabline': {
      \     'left': [['buffers']],
      \     'right': [[]],
      \ },
      \ 'active': {
      \   'left': [ [ 'mode',"paste", 'readonly' ],['relativepath', 'modified']],
      \   'right': [['coc_error', 'coc_warning', 'coc_hint', 'coc_info'], [ 'lineinfo' ]]
      \ },
      \ 'component_function': {
      \   'cocstatus': 'coc#status'
      \ },
      \ 'component_expand': {
      \   'buffers': 'lightline#bufferline#buffers',
      \   'coc_error'        : 'LightlineCocErrors',
      \   'coc_warning'      : 'LightlineCocWarnings',
      \   'coc_info'         : 'LightlineCocInfos',
      \   'coc_hint'         : 'LightlineCocHints',
      \   'coc_fix'          : 'LightlineCocFixes',
      \ },
      \ 'component_type': {
      \   'buffers'          : 'tabsel',
      \   'coc_error'        : 'error' ,
      \   'coc_warning'      : 'warning',
      \   'coc_info'         : 'tabsel',
      \   'coc_hint'         : 'middle',
      \   'coc_fix'          : 'middle',
      \ }
      \ }
