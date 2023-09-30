autocmd BufWritePost ~/.Xresources !xrdb % 
autocmd FileType * setlocal formatoptions-=c formatoptions-=r formatoptions-=o " Disable automatic commenting

augroup filetypes
    autocmd!
    au BufNewFile,BufRead *.ts setlocal filetype=typescript
    au BufNewFile,BufRead *.tsx setlocal filetype=typescript.tsx
    au BufNewFile,BufRead *.jsx setlocal filetype=javascript.jsx
    au BufNewFile,BufRead *.scss,*.css setlocal filetype=scss
    au BufNewFile,BufRead tsconfig.json setlocal filetype=jsonc
augroup end

set path+=** " Paths to look for when doing searches
set hidden " Dont ask for ! when changing buffer

let g:python3_host_prog = expand('~/.virtualenv/nvim/bin/python')

let g:livepreview_previewer = 'mimeopen'

let g:vim_jsx_pretty_colorful_config = 1 " Jsx extra syntax highlighting
