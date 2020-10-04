let g:airline_powerline_fonts = 1
let g:airline_theme='dracula'
let g:airline#extensions#tabline#enabled = 1
let g:airline#extensions#tmuxline#enabled = 1
let g:airline#extensions#tabline#buffer_idx_mode = 1
let g:airline#extensions#tabline#formatter = 'jsformatter'

autocmd User CocStatusChange,CocDiagnosticChange AirlineRefresh


"let g:airline_section_a=''       "(mode, crypt, paste, spell, iminsert)
"let g:airline_section_b=''       "(hunks, branch)[*]
"let g:airline_section_c=''       "(bufferline or filename, readonly)
"let g:airline_section_gutter=''  "(csv)
let g:airline_section_x=''       "(tagbar, filetype, virtualenv)
let g:airline_section_y=''       "(fileencoding, fileformat)
"let g:airline_section_z=''       "(percentage, line number, column number)
"let g:airline_section_error   "(ycm_error_count, syntastic-err, eclim,
"languageclient_error_count)
"let g:airline_section_warning='' "(ycm_warning_count, syntastic-warn, languageclient_warning_count, whitespace)

" remove separators for empty sections
let g:airline_skip_empty_sections = 1
let g:airline#parts#ffenc#skip_expected_string='utf-8[unix]'


"
let g:airline_left_sep = ''
let g:airline_left_alt_sep = ''
"let g:airline_right_sep = ''
"let g:airline_right_alt_sep = ''
let g:airline_right_sep = ''
let g:airline_right_alt_sep = ''
if !exists('g:airline_symbols')
  let g:airline_symbols = {}
endif

let g:airline_symbols.branch = ''
let g:airline_symbols.readonly = ''
let g:airline_symbols.linenr = 'Ξ'
let g:airline_symbols.maxlinenr = ' '
let g:airline_symbols.dirty='⚡'
let g:airline#extensions#coc#enabled = 1
let airline#extensions#coc#error_symbol = 'E:'
let airline#extensions#coc#warning_symbol = 'W:'
let airline#extensions#coc#stl_format_err = '%E{[%e(#%fe)]}'
let airline#extensions#coc#stl_format_warn = '%W{[%w(#%fw)]}'
"let g:airline#extensions#tabline#left_sep = ' '
"let g:airline#extensions#tabline#left_alt_sep = '|'
" enable tabline
"let g:airline#extensions#tabline#enabled = 1
"let g:airline#extensions#tabline#left_sep = ''
"let g:airline#extensions#tabline#left_alt_sep = ''
"let g:airline#extensions#tabline#right_sep = ''
"let g:airline#extensions#tabline#right_alt_sep = ''

" enable powerline fonts
"let g:airline_powerline_fonts = 1
"let g:airline_left_sep = ''
"let g:airline_right_sep = ''

"" Switch to your current theme
"let g:airline_theme = 'onedark'

"" Always show tabs
"set showtabline=2

"" We don't need to see things like -- INSERT -- anymore
set noshowmode
