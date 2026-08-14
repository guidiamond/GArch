local fn = vim.fn

local function ensure_lazy()
	local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
	if not vim.loop.fs_stat(lazypath) then
		fn.system({
			"git",
			"clone",
			"--filter=blob:none",
			"https://github.com/folke/lazy.nvim.git",
			"--branch=stable", -- latest stable release
			lazypath,
		})
		print("Installing lazy close and reopen Neovim...")
	end
	vim.opt.rtp:prepend(lazypath)
end

ensure_lazy()

local status_ok, lazy = pcall(require, "lazy")
if not status_ok then
	return
end

local function generate_colorscheme_setup(opts, name, is_main)
	if is_main then
		opts.priority = 1000
		opts.lazy = false
	else
		opts.enabled = false
	end
	opts.config = function()
		-- Try loading custom colorscheme setup from plugins.colorschemes.<colorscheme_name>
		local custom_colorscheme_cfg_loaded, _ = pcall(require, "plugins.colorschemes." .. name)
		local cscheme = vim.g.colors_name -- Check if a colorscheme is already loaded in plugins.colorschemes.<colorscheme_name>

		if not custom_colorscheme_cfg_loaded or cscheme == nil then
			-- If it doesn't exist, load it with the default command
			---@diagnostic disable-next-line: param-type-mismatch
			local colorscheme_loaded, _ = pcall(vim.cmd, "colorscheme " .. name)
			if not colorscheme_loaded then
				print("No colorscheme found with name: " .. name)
				return
			end
		end
	end
	return opts
end

local function load_config(name, no_prefix)
	return function()
		if no_prefix then
			return require(name)
		end
		return require("plugins." .. name)
	end
end

lazy.setup({
	-- Colorschemes
	generate_colorscheme_setup({
		"challenger-deep-theme/vim",
		name = "challenger-deep",
	}, "challenger_deep"),
	generate_colorscheme_setup({
		"catppuccin/nvim",
		name = "catppuccin",
	}, "catppuccin"),
	generate_colorscheme_setup({
		"rebelot/kanagawa.nvim",
		name = "kanagawa",
	}, "kanagawa"),

	-- OUTDATED/NOT MAINTAINED COLORSCHEMES
	-- generate_colorscheme_setup({
	-- 	"pineapplegiant/spaceduck",
	-- 	branch = "main",
	-- }, "spaceduck"),
	-- generate_colorscheme_setup({
	-- 	"tomasr/molokai",
	-- }, "molokai"),
	generate_colorscheme_setup({
		"dracula/vim",
		name = "dracula",
	}, "dracula"),
	generate_colorscheme_setup({
		"folke/tokyonight.nvim",
		branch = "main",
	}, "tokyonight"),
	generate_colorscheme_setup({
		"navarasu/onedark.nvim",
	}, "onedark", true),

	-- Vim Bars
	{
		"nvim-lualine/lualine.nvim",
		dependencies = { "nvim-tree/nvim-web-devicons" },
		config = load_config("lualine"),
	},
	{
		"akinsho/bufferline.nvim",
		version = "*",
		dependencies = { "nvim-tree/nvim-web-devicons" },
		config = load_config("bufferline"),
	},
	{
		"nvim-tree/nvim-tree.lua",
		dependencies = { "nvim-tree/nvim-web-devicons" },
		config = load_config("nvim-tree"),
	},
	-- Vim Search & Replace
	{
		"nvim-pack/nvim-spectre", -- Search and Replace
		dependencies = {
			"nvim-tree/nvim-web-devicons", -- Icons
			"nvim-lua/plenary.nvim", -- Asynchronous programming using coroutines
			-- External deps: (need to be installed externally) BurntSushi/ripgrep (finder) sed (replace tool)
		},
		config = load_config("nvim-spectre"),
	},
	{
		"nvim-telescope/telescope.nvim", -- Finder
		version = "0.1.x",
		dependencies = {
			"nvim-lua/plenary.nvim", -- Asynchronous programming using coroutines
		},
		config = load_config("telescope"),
	},
	{
		"ThePrimeagen/harpoon",
		branch = "harpoon2",
		dependencies = { "nvim-lua/plenary.nvim" },
	},
	{
		"nvim-telescope/telescope-fzf-native.nvim", -- Native FZF sorter that uses compiled C to do the matching, supports fzf syntax
		build = "make",
		dependencies = {
			"nvim-telescope/telescope.nvim", -- Finder
		},
	},
	{
		"nvim-telescope/telescope-media-files.nvim", -- Preview images, pdf, epub, video, and fonts from Neovim using Telescope.
		dependencies = {
			"nvim-telescope/telescope.nvim", -- Finder
			"nvim-lua/plenary.nvim", -- Asynchronous programming using coroutines
			"nvim-lua/popup.nvim", -- Implementation of the Popup API from vim in Neovim
			-- Chafa (required for image support)
			-- ImageMagick (optional, for svg previews)
			-- fd / rg / find or fdfind in Ubuntu/Debian.
			-- ffmpegthumbnailer (optional, for video preview support)
			-- pdftoppm (optional, for pdf preview support. Available in the AUR as poppler package.)
			-- epub-thumbnailer (optional, for epub preview support.)
			-- fontpreview (optional, for font preview support)
		},
	},
	-- Vim Movement
	{ "unblevable/quick-scope", init = load_config("quickscope") }, -- Colors for fnameter movement with (t or f)
	{
		"https://codeberg.org/andyg/leap.nvim",
		config = load_config("leap"),
	}, -- Two key movement

	-- Git
	{ "lewis6991/gitsigns.nvim", config = load_config("gitsigns") }, -- Git integration: signs, hunk actions, blame...
	{ "tpope/vim-fugitive" }, -- Git wrapper

	-- Extra Functionality
	{ "ludovicchabant/vim-gutentags", config = load_config("gutentags") }, -- Tag management and (re)generation
	{
		"kylechui/nvim-surround",
		version = "*", -- Use for stability; omit to use `main` branch for the latest features
		event = "VeryLazy",
		config = load_config("nvim-surround"),
	}, -- Surround selections
	{
		"windwp/nvim-autopairs",
		event = "InsertEnter",
		config = load_config("nvim-autopairs"),
	}, -- Insert or delete brackets, parentesis, quotes in pair

	{ "akinsho/toggleterm.nvim", config = load_config("toggleterm") },
	{
		"numToStr/Comment.nvim",
		config = load_config("comment"),
		dependencies = "JoosepAlviste/nvim-ts-context-commentstring", -- Make comments based on the cursor location in the file using treesitter
	}, -- Commenting plugin

	{
		"folke/which-key.nvim",
		config = load_config("keys.whichkey", true),
		init = function()
			vim.o.timeout = true
			vim.o.timeoutlen = 400
		end,
		event = "VeryLazy", -- Can load later and are not important for the initial UI
	}, -- Displays available keybindings in popup (lua version)
	{ "moll/vim-bbye" }, -- :Bdelete and :Bwipeout
	{ "RRethy/vim-illuminate" }, -- Automatically highlighting other uses of the word under the cursor
	{
		"L3MON4D3/LuaSnip",
		build = "make install_jsregexp", -- install jsregexp (optional)
		dependencies = {
			"rafamadriz/friendly-snippets", -- Snippets collection for a set of different programming languages
		},
	}, -- Snippet engine written in lua
	{
		"github/copilot.vim",
		-- config = load_config("copilot")
		init = load_config("copilot"),
	},
	{
		"folke/trouble.nvim",
		config = load_config("trouble"),
		dependencies = { "nvim-tree/nvim-web-devicons" },
	}, -- Pretty list for diagnostics, references, telescope results, quickfix and location lists
	{
		"hrsh7th/nvim-cmp",
		config = load_config("cmp"),
		dependencies = {
			"hrsh7th/cmp-buffer", -- Buffer completions,
			"hrsh7th/cmp-path", -- Path completions
			"hrsh7th/cmp-nvim-lsp", -- Lsp completions
			"hrsh7th/cmp-nvim-lua", -- Lua cfg completions
			"hrsh7th/cmp-cmdline", -- Cmdline completions
			"saadparwaiz1/cmp_luasnip", -- Snippet completions
		},
	}, -- Completion Plugin
	{
		"mason-org/mason.nvim",
	},
	{
		"mason-org/mason-lspconfig.nvim",
	},
	{
		"neovim/nvim-lspconfig",
		config = load_config("lsp"),
		dependencies = {
			-- "williamboman/mason.nvim", -- Simple to use language server installer
			-- "williamboman/mason-lspconfig.nvim", -- Bridges mason.nvim with the lspconfig plugin
			"nvimtools/none-ls.nvim", -- Formatters and linters
		},
	}, -- Enable LSP (collection of lsp configs)
	{
		"b0o/schemastore.nvim",
	},
	{
		"nvimtools/none-ls.nvim",
		dependencies = {
			"nvimtools/none-ls-extras.nvim",
		},
	},
	{
		"pmizio/typescript-tools.nvim",
		dependencies = { "nvim-lua/plenary.nvim", "neovim/nvim-lspconfig" },
		config = load_config("typescript-tools"),
	},
	{
		"nvim-treesitter/nvim-treesitter", -- Syntax highlighting
		lazy = false, -- The `main` branch does not support lazy-loading
		build = ":TSUpdate", -- Parsers are pinned per-plugin-version and must be kept in sync
		dependencies = {
			-- "p00f/nvim-ts-rainbow", -- Rainbow parentheses for neovim using treesitter
			"JoosepAlviste/nvim-ts-context-commentstring", -- Make comments based on the cursor location in the file using treesitter
		},
		config = load_config("treesitter"),
	},
	{
		"HiPhish/rainbow-delimiters.nvim", -- Rainbow parentheses for neovim using treesitter
		dependencies = {
			-- "p00f/nvim-ts-rainbow", -- Rainbow parentheses for neovim using treesitter
			"nvim-treesitter/nvim-treesitter", -- Make comments based on the cursor location in the file using treesitter
		},
		config = load_config("rainbow-delimiters"),
	},
	{ "mfussenegger/nvim-dap", "nvim-neotest/nvim-nio" },
	{
		"nvim-neotest/neotest",
		dependencies = {
			"nvim-neotest/nvim-nio",
			"nvim-lua/plenary.nvim",
			"antoinemadec/FixCursorHold.nvim",
			"nvim-treesitter/nvim-treesitter",
			"nvim-neotest/neotest-python", -- Python adapter
		},
		config = load_config("neotest"),
	},
	{
		"mfussenegger/nvim-dap",
		dependencies = { "rcarriga/nvim-dap-ui" }, -- Debugger UI
		config = load_config("dap"),
	}, -- Debugger adapter
	{
		"nvimdev/lspsaga.nvim",
		config = load_config("lspsaga"),
		dependencies = {
			"nvim-treesitter/nvim-treesitter",
			"nvim-tree/nvim-web-devicons",
		},
	},
	{
		"OXY2DEV/markview.nvim",
		lazy = false,
	},

	-- Plug 'KabbAmine/vCoolor.vim'
	-- Plug 'iamcco/markdown-preview.nvim', { 'do': 'cd app & yarn install'  } " Preview Markdown in real-time with a web browser
	-- Plug 'rrethy/vim-hexokinnamee', { 'do': 'make hexokinase' } " Color visualizer
	-- use({ "christoomey/vim-tmux-navigator" }) -- Tmux integration
}, {
	rocks = { hererocks = false }, -- Use system luarocks (pacman) instead of hererocks
})
