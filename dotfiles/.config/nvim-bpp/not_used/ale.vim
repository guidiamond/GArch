autocmd BufWrite *.css,*.scss silent! ALEFix
let g:ale_linters = {'jsx':[],'tsx':[],'javascript':[],'typescript':[],'css': ['stylelint'], 'scss': ['stylelint']}
let g:ale_fixers = {'css': ['stylelint'], 'scss': ['stylelint']}
