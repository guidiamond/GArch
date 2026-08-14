local status_ok, which_key = pcall(require, "which-key")
if not status_ok then
	return
end

local setup = {
	plugins = {
		marks = true, -- shows a list of your marks on ' and `
		registers = true, -- shows your registers on " in NORMAL or <C-r> in INSERT mode
		spelling = {
			enabled = true, -- enabling this will show WhichKey when pressing z= to select spelling suggestions
			suggestions = 20, -- how many suggestions should be shown in the list?
		},
		-- the presets plugin, adds help for a bunch of default keybindings in Neovim
		-- No actual key bindings are created
		presets = {
			operators = false, -- adds help for operators like d, y, ... and registers them for motion / text object completion
			motions = true, -- adds help for motions
			text_objects = true, -- help for text objects triggered after entering an operator
			windows = true, -- default bindings on <c-w>
			nav = true, -- misc bindings to work with windows
			z = true, -- bindings for folds, spelling and others prefixed with z
			g = true, -- bindings for prefixed with g
		},
	},
	-- add operators that will trigger motion and text object completion
	-- to enable all native operators, set the preset / operators plugin above
	-- operators = { gc = "Comments" },
	key_labels = {
		-- override the label used to display some keys. It doesn't effect WK in any other way.
		-- For example:
		-- ["<space>"] = "SPC",
		-- ["<cr>"] = "RET",
		-- ["<tab>"] = "TAB",
	},
	icons = {
		breadcrumb = "»", -- symbol used in the command line area that shows your active key combo
		separator = "➜", -- symbol used between a key and it's label
		group = "+", -- symbol prepended to a group
	},
	popup_mappings = {
		scroll_down = "<c-d>", -- binding to scroll down inside the popup
		scroll_up = "<c-u>", -- binding to scroll up inside the popup
	},
	window = {
		border = "rounded", -- none, single, double, shadow
		position = "bottom", -- bottom, top
		margin = { 1, 0, 1, 0 }, -- extra window margin [top, right, bottom, left]
		padding = { 2, 2, 2, 2 }, -- extra window padding [top, right, bottom, left]
		winblend = 0,
	},
	layout = {
		height = { min = 4, max = 25 }, -- min and max height of the columns
		width = { min = 20, max = 50 }, -- min and max width of the columns
		spacing = 3, -- spacing between columns
		align = "left", -- align columns left, center or right
	},
	ignore_missing = true, -- enable this to hide mappings for which you didn't specify a label
	hidden = { "<silent>", "<cmd>", "<Cmd>", "<CR>", "call", "lua", "^:", "^ " }, -- hide mapping boilerplate
	show_help = true, -- show help message on the command line when the popup is visible
	triggers = "auto", -- automatically setup triggers
	-- triggers = {}, -- or specify a list manually
	triggers_blacklist = {
		-- list of mode / prefixes that should never be hooked by WhichKey
		-- this is mostly relevant for key maps that start with a native binding
		-- most people should not need to change this
		i = { "j", "k" },
		v = { "j", "k" },
	},
}

local function get_opts(mode)
	return {
		mode = mode, -- NORMAL mode
		buffer = nil, -- Global mappings. Specify a buffer number for buffer local mappings
		silent = true, -- use `silent` when creating keymaps
		noremap = true, -- use `noremap` when creating keymaps
		nowait = true, -- use `nowait` when creating keymaps
	}
end

function clean_buffers(mappings)
	for idx = 1, 9 do
		mappings[tostring(idx)] = { "", "" }
		mappings["d" .. tostring(idx)] = { "", "" }
	end
	return mappings
end

function get_buffers()
	local vim_fn = vim.fn
	local mappings = {}
	mappings = clean_buffers(mappings)
	for buff_num, buffer in pairs(vim_fn.getbufinfo({ buflisted = 1 })) do
		-- TODO: allow more than 9 buffers to be used by which_key
		if buff_num >= 10 then
			break
		end
		local map_buf_num = tostring(buff_num)
		local real_buf_num = tostring(buffer.bufnr)
		local clean_buffer_name = "  " .. vim_fn.fnamemodify(buffer.name, ":.:s?index??:s?src??")

		mappings[map_buf_num] = { "<cmd>:b " .. real_buf_num .. "<CR>", clean_buffer_name }
		mappings["d" .. map_buf_num] = { "<cmd>:Bdelete " .. real_buf_num .. "<CR>", clean_buffer_name }
	end

	which_key.register(mappings, { prefix = "<leader>" })
	return mappings
end

local mappings = {
	["<leader>"] = {
		c = {
			-- Not running
			name = "+NerdCommenter",
			s = { "<Plug>NERDCommenterSexy", "Sexy" },
			u = { "<Plug>NERDCommenterUncomment", "Uncomment" },
			y = { "<Plug>NERDCommenterUncomment", "Yank && comment" },
			c = { "<Plug>NERDCommenterComment", "Comment" },
			["$"] = { "<Plug>NerdCommenterToEOL", "to EOL" },
			A = { "<Plug>NerdCommenterAppend", "Append to the end" },
		},
		d = {
			name = "+Delete Buffers",
			d = { "<cmd>Bdelete %<CR>", "Current" },
			r = { "<cmd>BufferLineCloseRight<CR>", "To the Right" },
			l = { "<cmd>BufferLineCloseLeft<CR>", "To the Left" },
			-- Missing
		},
		t = {
			name = "+ToggleTerm",
			g = { "<cmd>lua _LAZYGIT_TOGGLE()<CR>", "Lazygit" },
			n = { "<cmd>lua _NODE_TOGGLE()<CR>", "Node" },
			r = { "<cmd>lua _RANGER_TOGGLE()<CR>", "Ranger" },
		},
		v = {
			name = "+Vim",
			e = { "<cmd>vsplit $MYVIMRC<CR>", "Edit" },
			s = { "<cmd>source $MYVIMRC<CR>", "Source" },
		},
		["\\"] = { "<cmd>bn<CR>", "Next Buffer" },
		["|"] = { "<cmd>bp<CR>", "Previous Buffer" },
	},
	["<space>"] = {
		d = {
			name = "+Debug",
			t = { "<cmd>lua require'dap'.toggle_breakpoint()<cr>", "Toggle Breakpoint" },
			b = { "<cmd>lua require'dap'.step_back()<cr>", "Step Back" },
			c = { "<cmd>lua require'dap'.continue()<cr>", "Continue" },
			C = { "<cmd>lua require'dap'.run_to_cursor()<cr>", "Run To Cursor" },
			d = { "<cmd>lua require'dap'.disconnect()<cr>", "Disconnect" },
			g = { "<cmd>lua require'dap'.session()<cr>", "Get Session" },
			i = { "<cmd>lua require'dap'.step_into()<cr>", "Step Into" },
			o = { "<cmd>lua require'dap'.step_over()<cr>", "Step Over" },
			u = { "<cmd>lua require'dap'.step_out()<cr>", "Step Out" },
			p = { "<cmd>lua require'dap'.pause()<cr>", "Pause" },
			r = { "<cmd>lua require'dap'.repl.toggle()<cr>", "Toggle Repl" },
			s = { "<cmd>lua require'dap'.continue()<cr>", "Start" },
			q = { "<cmd>lua require'dap'.close()<cr>", "Quit" },
			U = { "<cmd>lua require'dapui'.toggle({reset = true})<cr>", "Toggle UI" },
		},
		e = { "<cmd>NvimTreeToggle<CR>", "Nvim tree Toggle" },
		f = {
			name = "+Find",
			a = { "<cmd>Telescope buffers<CR>", "Buffers search" },
			b = { "<cmd>Telescope current_buffer_fuzzy_find<CR>", "Current buffer word search" },
			c = { "<cmd>Telescope git_commits<CR>", "Git commits search" },
			d = { "<cmd>Telescope git_branches<CR>", "Git branches search" },
			e = { "<cmd>Telescope git_status<CR>", "Git diff search" },
			f = { "<cmd>Telescope live_grep<CR>", "word search" },
			h = { "<cmd>Telescope search_history<CR>", "CMD history search" },
			l = { "<cmd>lua require('telescope.builtin').live_grep({grep_open_files=true})<CR>", "Buffers word search" },
			m = { "<cmd>lua require('telescope.builtin').marks()<CR>", "Buffers word search" },
			p = { "<cmd>Telescope fd fd_command=fd,--hidden,--files prompt_prefix=🔍<CR>", "Files search" },
			s = { "<cmd>Telescope git_stash<CR>", "Git stash search" },
			t = { "<cmd>Telescope tags<CR>", "Tags search" },
		},
		y = { '"+y', "Yank2clipboard" },
		["<space>"] = { "za", "Close Fold" },
	},
}

which_key.setup(setup)
which_key.register(mappings, get_opts("n"))
which_key.register(mappings, get_opts("v"))

vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter", "BufDelete" }, { callback = get_buffers })
-- local keymap = vim.api.nvim_set_keymap
-- keymap('n','\\',':WhichKey \\<CR>',{ noremap = true, silent = true })
