autocmd User CocStatusChange,CocDiagnosticChange AirlineRefresh
autocmd VimEnter * call AirlineInit()

"" Theme
let g:airline_powerline_fonts = 1
let g:airline_theme='dracula'

"" Extensions
let g:airline_extensions = ["branch",'hunks','tabline','coc']
" Tabline
let g:airline#extensions#tabline#buffer_idx_mode = 1
let g:airline#extensions#tabline#formatter = 'unique_tail'
" COC
let airline#extensions#coc#error_symbol = ' '
let airline#extensions#coc#warning_symbol = ' '

"" Sections
let g:airline#extensions#default#layout = [['a', 'b', 'c'], ['x', 'z', 'warning', 'error']]
function! AirlineInit()
  let g:airline_section_a = airline#section#create(['mode', 'crypt', 'paste', 'spell', 'iminsert']) "(mode, crypt, paste, spell, iminsert)
  let g:airline_section_b = airline#section#create(['hunks', ' ', 'branch'])
  let g:airline_section_c = airline#section#create([' '])

  let g:airline_section_x = airline#section#create(['file'])       "(tagbar, filetype, virtualenv)
  let g:airline_section_z = airline#section#create(['%p','%%', ' ', 'linenr', '', 'maxlinenr'])       "(tagbar, filetype, virtualenv)

endfunction

"" Separators
let g:airline_left_sep = ''
let g:airline_left_alt_sep = ''
let g:airline_right_sep = ''
let g:airline_right_alt_sep = ''

"" Symbols
" Used to avoid variable not found error
if !exists('g:airline_symbols')
  let g:airline_symbols = {}
endif
let g:airline_symbols.branch = ''
let g:airline_symbols.readonly = ''
let g:airline_symbols.linenr = 'Ξ '
let g:airline_symbols.maxlinenr = ''
let g:airline_symbols.dirty='⚡'

"" General
" Remove separators for empty sections
let g:airline_skip_empty_sections = 1 
" Remove utf-8 string from bar
"" Hides vim's default bar
set noshowmode
"" Always show tabs
set showtabline=2




" The following list of parts are predefined by vim-airline.
"
" * `mode`         displays the current mode
" * `iminsert`     displays the current insert method
" * `paste`        displays the paste indicator
" * `crypt`        displays the crypted indicator
" * `spell`        displays the spell indicator
" * `filetype`     displays the file type
" * `readonly`     displays the read only indicator
" * `file`         displays the filename and modified indicator
" * `path`         displays the filename (absolute path) and modifier indicator
" * `linenr`       displays the current line number
" * `maxlinenr`    displays the number of lines in the buffer
" * `ffenc`        displays the file format and encoding



"" Interesting icons
"
"
"
