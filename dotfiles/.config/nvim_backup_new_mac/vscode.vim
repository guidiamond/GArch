call plug#begin()
Plug 'iamcco/markdown-preview.nvim', { 'do': 'cd app & yarn install'  }

Plug 'tpope/vim-surround'
Plug 'jiangmiao/auto-pairs'
Plug 'scrooloose/nerdcommenter' " Multi-line commenter
Plug 'mlaursen/vim-react-snippets'
call plug#end()
source ~/.config/nvim/cfgs/general.vim

nmap <c-c> <esc>
imap <c-c> <esc>
vmap <c-c> <esc>
omap <c-c> <esc>
nnoremap <c-c> :noh <CR>
