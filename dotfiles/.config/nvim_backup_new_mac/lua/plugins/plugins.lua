local fn = vim.fn

-- Automatically install packer
local ensure_packer = function()
	local install_path = fn.stdpath("data") .. "/site/pack/packer/start/packer.nvim"
	if fn.empty(fn.glob(install_path)) > 0 then
		fn.system({
			"git",
			"clone",
			"--depth",
			"1",
			"https://github.com/wbthomason/packer.nvim",
			install_path,
		})
		print("Installing packer close and reopen Neovim...")
		vim.cmd([[packadd packer.nvim]])
		return true
	end
	return false
end

local packer_bootstrap = ensure_packer()

-- Autocommand that reloads neovim whenever you save the plugins.lua file
vim.cmd([[
  augroup packer_user_config
    autocmd!
    autocmd BufWritePost plugins.lua source <afile> | PackerSync
  augroup end
]])

local status_ok, packer = pcall(require, "packer")
if not status_ok then
	return
end

-- Have packer use a popup window
packer.init({
	ensure_dependencies = true, -- Should packer install plugin dependencies?
	display = {
		open_fn = function()
			return require("packer.util").float({ border = "rounded" })
		end,
	},
})

-- Install your plugins here
return packer.startup(function(use)
	use({ "wbthomason/packer.nvim" })
	-- Colorschemes
	use({ "challenger-deep-theme/vim", as = "challenger-deep" })
	use({ "pineapplegiant/spaceduck", branch = "main" })
	use({ "dracula/vim", as = "dracula" })
	use({ "tomasr/molokai" })
	use({ "sonph/onehalf", rtp = "vim/" })
	use({ "joshdick/onedark.vim" })
	use({ "folke/tokyonight.nvim", branch = "main" })

	-- Vim Bars
	use({ "nvim-lualine/lualine.nvim", requires = { "kyazdani42/nvim-web-devicons" } })
	use({ "nvim-tree/nvim-tree.lua", requires = { "nvim-tree/nvim-web-devicons" } })
	use({ "akinsho/bufferline.nvim", tag = "v3.*", requires = "nvim-tree/nvim-web-devicons" })

	use({ "brooth/far.vim" }) -- Completion
	-- Vim Movement
	use({ "nvim-telescope/telescope.nvim", tag = "0.1.x", requires = { "nvim-lua/plenary.nvim" } })
	use({ "nvim-telescope/telescope-fzf-native.nvim", run = "make" })
	use({ "unblevable/quick-scope" }) -- Colors for faster movement with (t or f)
	use({ "justinmk/vim-sneak" }) -- Two key movement
	-- Git
	use({ "ludovicchabant/vim-gutentags" })
	use({ "lewis6991/gitsigns.nvim" }) -- Uses signs to indicate modified files
	use({ "tpope/vim-fugitive" })

	-- Extra Functionality
	-- use({ "christoomey/vim-tmux-navigator" }) -- Tmux integration
	use({ "akinsho/toggleterm.nvim" })
	use({ "lewis6991/impatient.nvim" }) -- Loads nvim faster
	use({ "tpope/vim-surround" }) -- Mappings to easily delete, change and add such surroundings in pairs
	use({ "jiangmiao/auto-pairs" }) -- Insert or delete brackets, parens, quotes in pair
	use({ "tomtom/tcomment_vim" }) -- Line commenter
	use({ "folke/which-key.nvim" }) -- Displays available keybindings in popup (lua version)
	use({ "moll/vim-bbye" })
	-- Snippets
	use({ "L3MON4D3/LuaSnip" })
	use({ "rafamadriz/friendly-snippets" }) -- Snippets collection for a set of different programming languages
	use("mlaursen/vim-react-snippets")

	-- Cmp
	use({ "hrsh7th/nvim-cmp" }) -- Completion Plugin
	use({ "hrsh7th/cmp-buffer" }) -- Buffer completions
	use({ "hrsh7th/cmp-path" }) -- Path completions
	use({ "hrsh7th/cmp-nvim-lsp" }) -- Lsp completions
	use({ "hrsh7th/cmp-nvim-lua" }) -- Lua cfg completions
	use({ "hrsh7th/cmp-cmdline" }) -- Cmdline completions
	use({ "saadparwaiz1/cmp_luasnip" }) -- Snippet completions
	-- LSP
	use({ "neovim/nvim-lspconfig" }) -- Enable LSP (collection of lsp configs)
	use({ "williamboman/mason.nvim" }) -- Simple to use language server installer
	use({ "williamboman/mason-lspconfig.nvim" }) -- Bridges mason.nvim with the lspconfig plugin
	use({ "williamboman/nvim-lsp-installer" }) -- LSP installer
	use({ "RRethy/vim-illuminate" }) -- Automatically highlighting other uses of the word under the cursor
	use({ "jose-elias-alvarez/null-ls.nvim" }) -- Formatters and linters
	use({
		"nvim-treesitter/nvim-treesitter", -- Syntax highlighting
		requires = { "p00f/nvim-ts-rainbow" }, -- Rainbow parentheses for neovim using tree-sitter
	})
	use({
		"mfussenegger/nvim-dap", -- Debugger adapter
		requires = { "rcarriga/nvim-dap-ui" }, -- Debugger UI
	})

	-- Plug 'KabbAmine/vCoolor.vim'
	-- Plug 'iamcco/markdown-preview.nvim', { 'do': 'cd app & yarn install'  } " Preview Markdown in real-time with a web browser
	-- Plug 'rrethy/vim-hexokinase', { 'do': 'make hexokinase' } " Color visualizer

	if packer_bootstrap then
		require("packer").sync()
	end
end)
