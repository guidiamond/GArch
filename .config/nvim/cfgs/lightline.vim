 "Configs
"set showtabline=2  Show buffers
"set noshowmode disable mode at the bottom
"let g:lightline#bufferline#enable_devicons = 1
"let g:lightline#bufferline#filename_modifier = ":gs?index??" " Tab filename/path format
"let g:lightline#bufferline#filename_modifier = :.:gs?src/modules/??:r:gs?index??" " Tab filename/path format
"let g:lightline#bufferline#shorten_path = 0 
"let g:lightline#bufferline#show_number = 2
"let g:lightline#bufferline#unicode_symbols = 1
"let g:lightline#bufferline#number_map = {
"\ 0: '⁰', 1: '¹', 2: '²', 3: '³', 4: '⁴',
"\ 5: '⁵', 6: '⁶', 7: '⁷', 8: '⁸', 9: '⁹'}

"let g:lightline = {
      "\ 'colorscheme': 'dracula',
      "\ 'active': {
      "\   'left': [ [ 'mode',"paste" ],['relativepath']],
      "\   'right': [[ 'coc_errors', 'coc_warnings', 'coc_ok' ], [ 'lineinfo','coc_status']]
      "\ },
      "\'component_expand': {
      "\  'buffers': 'lightline#bufferline#buffers',
      "\},
      "\'component_type': {
      "\     'buffers': 'tabsel',
      "\},
      "\'tabline': {
      "\     'left': [['buffers']],
      "\     'right': [[]],
      "\},
      "\}
 "register compoments:
"call lightline#coc#register()
