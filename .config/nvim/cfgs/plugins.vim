call plug#begin()
" Colorschemes
Plug 'challenger-deep-theme/vim', { 'as': 'challenger-deep' } " Colorscheme
Plug 'iamcco/markdown-preview.nvim', { 'do': 'cd app & yarn install'  }
Plug 'brooth/far.vim'
Plug 'preservim/nerdtree'

Plug 'dracula/vim', { 'as': 'dracula' } " Colorscheme (used in lightline)
Plug 'styled-components/vim-styled-components', { 'branch': 'main' },
Plug 'joshdick/onedark.vim'
Plug 'vim-airline/vim-airline'
Plug 'puremourning/vimspector'
Plug 'unblevable/quick-scope'
Plug 'vim-airline/vim-airline-themes'
Plug 'luochen1990/rainbow'
Plug 'rrethy/vim-hexokinase', { 'do': 'make hexokinase' }
Plug 'christoomey/vim-tmux-navigator'
Plug 'justinmk/vim-sneak'
Plug 'HerringtonDarkholme/yats.vim'
Plug 'DougBeney/pickachu'
" Programming
Plug 'sheerun/vim-polyglot'
Plug 'neoclide/coc.nvim', {'branch': 'release'} " Linter
Plug 'tpope/vim-surround'
Plug 'jiangmiao/auto-pairs'
Plug 'https://github.com/mhinz/vim-signify'
" File manager
Plug 'liuchengxu/vim-which-key'
Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
Plug 'voldikss/vim-floaterm'
Plug 'junegunn/fzf.vim'
Plug 'ryanoasis/vim-devicons' " Icons for filetypes
Plug 'scrooloose/nerdcommenter' " Multi-line commenter
Plug 'mlaursen/vim-react-snippets'
" Extra functionality
"Plug 'https://github.com/ctrlpvim/ctrlp.vim' " Quick file finder
" Status bar
"Plug 'https://github.com/itchyny/lightline.vim' " Status bar
"Plug 'mengelbrecht/lightline-bufferline' " Shows buffer as tabs
"Plug 'josa42/vim-lightline-coc' " Coc integration
"Plug 'ap/vim-css-color'
"Plug 'dense-analysis/ale' " Linter
"Plug 'airblade/vim-gitgutter' " Git integration
"Plug 'airblade/vim-rooter'
call plug#end()
