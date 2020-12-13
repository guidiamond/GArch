function FixReactScssModules()
  silent! execute '%s/\(className=\)"\(.*\)"/\1{scss["\2"]}/g'
  silent! execute '%s/\(id=\)"\(.*\)"/\1{style["\2"]}/g'
endfunction

command! -nargs=0 FXSCSS   :call     FixReactScssModules()
