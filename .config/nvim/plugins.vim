call plug#begin()

" Colorscheme
Plug 'challenger-deep-theme/vim', { 'as': 'challenger-deep' }
Plug 'dracula/vim', { 'as': 'dracula' } " Vim airline theme
Plug 'joshdick/onedark.vim'
Plug 'ryanoasis/vim-devicons' " filetype icons

" Vim Bar
Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'

" Debug
Plug 'puremourning/vimspector'

" Bulk rename
Plug 'brooth/far.vim'

" Vim movement
Plug 'junegunn/fzf', { 'do': { -> fzf#install() } } " fuzzy finder update checker
Plug 'junegunn/fzf.vim' " fuzzy finder vim plugin
Plug 'unblevable/quick-scope' " Colors for faster movement with (t or f)
Plug 'justinmk/vim-sneak' " Two key movement
" Plug 'easymotion/vim-easymotion'

" Color
Plug 'DougBeney/pickachu' " Color picker
Plug 'rrethy/vim-hexokinase', { 'do': 'make hexokinase' } " Color visualizer
Plug 'luochen1990/rainbow' " Diff level of parentheses with multiple colors

" Git integration
Plug 'mhinz/vim-signify' " Uses signs to indicate modified files
Plug 'tpope/vim-fugitive'

" Language specific
Plug 'sheerun/vim-polyglot' " Generic language package
Plug 'jackguo380/vim-lsp-cxx-highlight' " Syntax highlight for c++
Plug 'neoclide/coc.nvim', {'branch': 'release'} " Language server
Plug 'iamcco/markdown-preview.nvim', { 'do': 'cd app & yarn install'  } " Preview Markdown in real-time with a web browser
Plug 'neoclide/jsonc.vim' " Jsonc
" Plug 'styled-components/vim-styled-components', { 'branch': 'main' } " Javascript Styled components
Plug 'mlaursen/vim-react-snippets' " Snippets for react

" Tmux integration
Plug 'christoomey/vim-tmux-navigator' " Tmux integration

" Extra functionality
Plug 'tpope/vim-surround' " Mappings to easily delete, change and add such surroundings in pairs
Plug 'jiangmiao/auto-pairs' " Insert or delete brackets, parens, quotes in pair.
Plug 'tomtom/tcomment_vim' " Line commenter
Plug 'liuchengxu/vim-which-key' " Displays available keybindings in popup.
Plug 'voldikss/vim-floaterm' " Terminal in popup




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
"Plug 'scrooloose/nerdcommenter' " Multi-line commenter
" File explorer
" Plug 'preservim/nerdtree'
" Plug 'tiagofumo/vim-nerdtree-syntax-highlight' " Coloring for nerdtree (dependency: 'ryanoasis/vim-devicons')

call plug#end()
