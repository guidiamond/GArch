function MyNerdToggle()
    if &filetype == 'nerdtree'
        :NERDTreeToggle
    else
        :NERDTreeFind
    endif
endfunction
map <C-n> :call MyNerdToggle()<CR>
let NERDTreeMouseMode=2
let NERDTreeMinimalUI = 1
let NERDTreeDirArrows = 1
let g:NERDTreeHighlightCursorline = 1
let g:NERDTreeQuitOnOpen=1
let NERDTreeShowHidden=1
let NERDTreeAutoDeleteBuffer = 1

augroup MouseInNERDTreeOnly
    autocmd!
    autocmd BufEnter NERD_tree_* set mouse=a
    autocmd BufLeave NERD_tree_* set mouse=
augroup END
