local status_ok, wk = pcall(require, "which-key")

if not status_ok then
	return
end

local setup = {
	keys = {
		scroll_down = "<c-d>", -- binding to scroll down inside the popup
		scroll_up = "<c-u>", -- binding to scroll up inside the popup
	},
	preset = "modern",
	win = {
		border = "rounded", -- none, single, double, shadow
		-- position = "bottom", -- bottom, top
		-- margin = { 1, 0, 1, 0 }, -- extra window margin [top, right, bottom, left]
		-- padding = { 2, 2, 2, 2 }, -- extra window padding [top, right, bottom, left]
		-- winblend = 0, -- value between 0-100 0 for fully opaque and 100 for fully transparent
		-- zindex = 1000, -- positive value to position WhichKey above other floating windows.
	},
	layout = {
		height = { min = 4, max = 25 }, -- min and max height of the columns
		width = { min = 20, max = 50 }, -- min and max width of the columns
		spacing = 3, -- spacing between columns
		align = "left", -- align columns left, center or right
	},
	-- ignore_missing = true, -- enable this to hide mappings for which you didn't specify a label
	-- hidden = { "<silent>", "<cmd>", "<Cmd>", "<CR>", "^:", "^ ", "^call ", "^lua " }, -- hide mapping boilerplate
	show_help = true, -- show help message on the command line when the popup is visible
	-- triggers = "auto", -- automatically setup triggers
	-- triggers = {}, -- or specify a list manually
	-- triggers_blacklist = {
	-- 	-- list of mode / prefixes that should never be hooked by WhichKey
	-- 	-- this is mostly relevant for key maps that start with a native binding
	-- 	-- most people should not need to change this
	-- 	i = { "j", "k" },
	-- 	v = { "j", "k" },
	-- },
}

wk.setup(setup)

local function get_opts(mode)
	return {
		mode = mode,
		buffer = nil, -- Global mappings. Specify a buffer number for buffer local mappings
		silent = true, -- Normal messages will not be given or added to the message history.
		noremap = true, -- Non recursive mapping (safer than remap)
		nowait = true, -- Lets your mapping trigger even if a longer mapping exists
	}
end

local function clean_buffers(mappings)
	for idx = 1, 9 do
		mappings[tostring(idx)] = { "", "" }
		mappings["d" .. tostring(idx)] = { "", "" }
	end
	return mappings
end

local function get_buffers()
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

	wk.register(mappings, { prefix = "<leader>" })
	return mappings
end

local function nvim_tree_toggle_focus()
	local tree_view = require("nvim-tree.view")
	if tree_view.is_visible() then
		local buf_name = vim.fn.expand("%")
		if string.sub(buf_name, 1, 8) == "NvimTree" then
			return vim.api.nvim_command("NvimTreeToggle")
		end
	end
	return vim.api.nvim_command("NvimTreeFocus")
end

local _, harpoon = pcall(require, "harpoon")

local conf = require("telescope.config").values
local function toggle_telescope(harpoon_files)
	local file_paths = {}
	for _, item in ipairs(harpoon_files.items) do
		table.insert(file_paths, item.value)
	end

	require("telescope.pickers")
		.new({}, {
			prompt_title = "Harpoon",
			finder = require("telescope.finders").new_table({
				results = file_paths,
			}),
			previewer = conf.file_previewer({}),
			sorter = conf.generic_sorter({}),
		})
		:find()
end

local function handle_format()
	local bufnr = vim.api.nvim_get_current_buf()
	local filetype = vim.bo.filetype
	local format_filter = require("plugins.lsp.handlers").format_filter

	local opts = {
		bufnr = bufnr,
		filter = function(fmt_client)
			return format_filter(fmt_client, bufnr)
		end,
	}

	-- jsonls freezes when formatting JSON files with syntax highlighting on
	if filetype == "json" or filetype == "jsonc" then
		vim.cmd("syntax off")
		vim.lsp.buf.format(opts)
		vim.cmd("syntax on")
	else
		opts.async = true
		vim.lsp.buf.format(opts)
	end
end

local function print_table(t)
	for key, value in pairs(t) do
		print(key, value)
	end
end

local function format_file_path_label(fpath)
	return vim.fn.fnamemodify(
		fpath,
		":." -- Removes everything before the current working directory (cwd)
			.. ":r" -- Removes the file extension
			.. ":s?/index??" -- Replaces (s) "index" with nothing
			.. ":s?src/??" -- Replaces (s) "src" with nothing
	)
end

wk.add({
	{
		"<leader>",
		group = "buffers",
		expand = function()
			local spec = {}

			local buf_infos = vim.fn.getbufinfo({ buflisted = 1 })
			-- for _, buf in ipairs(bufinfo) do
			-- 	print(vim.inspect(buf))
			-- end
			--
			-- local buffers = vim.api.nvim_list_bufs()

			for buf_number, buf in ipairs(buf_infos) do
				-- buf_number refers to the index of the buffer in the list of buffers
				-- buf_number_real refers to the actual buffer number (the same as when you do :ls)
				local buf_number_ls = buf.bufnr

				spec[buf_number] = {
					tostring(buf_number),
					function()
						vim.api.nvim_set_current_buf(buf_number_ls)
					end,
					desc = format_file_path_label(buf.name),
					icon = { cat = "file", name = buf.name },
				}
			end
			return spec
		end,
	},
	{
		"<leader>d",
		group = "delete buffer",
		expand = function()
			local spec = {}

			local buf_infos = vim.fn.getbufinfo({ buflisted = 1 })
			-- for _, buf in ipairs(bufinfo) do
			-- 	print(vim.inspect(buf))
			-- end
			--
			-- local buffers = vim.api.nvim_list_bufs()

			for buf_number, buf in ipairs(buf_infos) do
				-- buf_number refers to the index of the buffer in the list of buffers
				-- buf_number_real refers to the actual buffer number (the same as when you do :ls)
				local buf_number_ls = buf.bufnr

				local buf_path_source = vim.fn.fnamemodify(
					buf.name,
					":." -- Removes everything before the current working directory (cwd)
				)

				spec[buf_number] = {
					tostring(buf_number),
					function()
						vim.cmd("Bdelete " .. buf_path_source)
					end,
					desc = format_file_path_label(buf.name),
					icon = { cat = "file", name = buf.name },
				}
			end
			return spec
		end,
	},
	{
		"<leader>dd",
		"<cmd>Bdelete %<CR>",
		desc = "Current",
		nowait = true,
		remap = false,
	},
	{
		"<leader>dl",
		"<cmd>BufferLineCloseLeft<CR>",
		desc = "To the Left",
		nowait = true,
		remap = false,
	},
	{
		"<leader>do",
		"<cmd>BufferLineCloseOthers<CR>",
		desc = "All but current",
		nowait = true,
		remap = false,
	},
	{
		"<leader>dr",
		"<cmd>BufferLineCloseRight<CR>",
		desc = "To the Right",
		nowait = true,
		remap = false,
	},
})

-- harpoon:list():select(1)
-- harpoon:list():add()
-- harpoon:list():prev()
-- harpoon.ui:toggle_quick_menu(harpoon:list())
-- harpoon:list():next()
wk.add({
	{
		"<space>a",
		group = "harpoon",
		expand = function()
			local spec = {}

			local a = harpoon:list()
			local harpoon_files = harpoon:list()
			for buf_number, item in ipairs(harpoon_files.items) do
				local file_path = item.value

				local teste = vim.fn.fnamemodify(
					file_path,
					":." -- Removes everything before the current working directory (cwd)
						.. ":r" -- Removes the file extension
						.. ":s?/index??" -- Replaces (s) "index" with nothing
						.. ":s?src/??" -- Replaces (s) "src" with nothing
				)
				spec[buf_number] = {
					tostring(buf_number),
					function()
						harpoon:list():select(buf_number)
					end,
					desc = format_file_path_label(file_path),
					icon = { cat = "file", name = file_path },
				}
			end

			return spec
		end,
	},
	{
		"<space>a<space>",
		function()
			harpoon:list():add()
		end,
		desc = "Add",
		nowait = true,
		remap = false,
	},
	{
		"<space>an",
		function()
			harpoon:list():next()
		end,
		desc = "Next",
		nowait = true,
		remap = false,
	},
	{
		"<space>aN",
		function()
			harpoon:list():prev()
		end,
		desc = "Previous",
		nowait = true,
		remap = false,
	},
	{
		"<space>al",
		function()
			harpoon.ui:toggle_quick_menu(harpoon:list())
		end,
		desc = "List",
		nowait = true,
		remap = false,
	},
})

-- local mappings = {
-- 	["<leader>"] = {
-- 		["1"] = { "<cmd>lua require('bufferline').go_to(1, true)<CR>", "Goto Buffer 1" },
-- 		["2"] = { "<cmd>lua require('bufferline').go_to(2, true)<CR>", "Goto Buffer 2" },
-- 		["3"] = { "<cmd>lua require('bufferline').go_to(3, true)<CR>", "Goto Buffer 3" },
-- 		["4"] = { "<cmd>lua require('bufferline').go_to(4, true)<CR>", "Goto Buffer 4" },
-- 		["5"] = { "<cmd>lua require('bufferline').go_to(5, true)<CR>", "Goto Buffer 5" },
-- 		["6"] = { "<cmd>lua require('bufferline').go_to(6, true)<CR>", "Goto Buffer 6" },
-- 		["7"] = { "<cmd>lua require('bufferline').go_to(7, true)<CR>", "Goto Buffer 7" },
-- 		["8"] = { "<cmd>lua require('bufferline').go_to(8, true)<CR>", "Goto Buffer 8" },
-- 		["9"] = { "<cmd>lua require('bufferline').go_to(9, true)<CR>", "Goto Buffer 9" },
-- 		d = {
-- 			name = "+Delete Buffers",
-- 			d = { "<cmd>Bdelete %<CR>", "Current" },
-- 			r = { "<cmd>BufferLineCloseRight<CR>", "To the Right" },
-- 			l = { "<cmd>BufferLineCloseLeft<CR>", "To the Left" },
-- 			o = { "<cmd>BufferLineCloseOthers<CR>", "All but current" },
-- 		},
-- 		t = {
-- 			name = "+ToggleTerm",
-- 			g = { "<cmd>lua _LAZYGIT_TOGGLE()<CR>", "Lazygit" },
-- 			n = { "<cmd>lua _NODE_TOGGLE()<CR>", "Node" },
-- 			p = { "<cmd>lua _PYTHON_TOGGLE()<CR>", "Python" },
-- 			r = { "<cmd>lua _RANGER_TOGGLE()<CR>", "Ranger" },
-- 			t = { "<cmd>ToggleTerm<CR>", "Terminal" },
-- 		},
-- 		v = {
-- 			name = "+Vim",
-- 			e = { "<cmd>vsplit $MYVIMRC<CR>", "Edit" },
-- 			s = { "<cmd>source $MYVIMRC<CR>", "Source" },
-- 		},
-- 		w = {
-- 			name = "+BufferLine",
-- 			w = { "<cmd>BufferLinePick<CR>", "Pick a buffer" },
-- 			d = { "<cmd>BufferLinePickClose<CR>", "Delete a buffer" },
-- 			p = { "<cmd>BufferLineTogglePin<CR>", "Pin buffer" },
-- 			a = { "<cmd>BufferLineMoveNext<CR>", "Move buffer next" },
-- 			A = { "<cmd>BufferLineMoveNext<CR>", "Move buffer prev" },
-- 		},
-- 		-- ["\\"] = { "<cmd>bn<CR>", "Next Buffer" },
-- 		-- ["|"] = { "<cmd>bp<CR>", "Previous Buffer" },
-- 		["\\"] = { "<cmd>BufferLineCycleNext<CR>", "Next Buffer" },
-- 		["|"] = { "<cmd>BufferLineCyclePrev<CR>", "Previous Buffer" },
-- 	},
-- 	["<space>"] = {
-- 		a = {
-- 			name = "+Harpooon",
-- 			n = {
-- 				function()
-- 					harpoon:list():next()
-- 				end,
-- 				"Next",
-- 			},
-- 			N = {
-- 				function()
-- 					harpoon:list():prev()
-- 				end,
-- 				"Previous",
-- 			},
-- 			["<space>"] = {
-- 				function()
-- 					harpoon:list():add()
-- 				end,
-- 				"Add",
-- 			},
-- 			["1"] = {
-- 				function()
-- 					harpoon:list():select(1)
-- 				end,
-- 				"Select 1",
-- 			},
-- 			["2"] = {
-- 				function()
-- 					harpoon:list():select(2)
-- 				end,
-- 				"Select 2",
-- 			},
-- 			["3"] = {
-- 				function()
-- 					harpoon:list():select(3)
-- 				end,
-- 				"List 3",
-- 			},
-- 			["4"] = {
-- 				function()
-- 					harpoon:list():select(4)
-- 				end,
-- 				"List 4",
-- 			},
-- 			l = {
-- 				function()
-- 					harpoon.ui:toggle_quick_menu(harpoon:list())
-- 				end,
-- 				"List",
-- 			},
-- 		},
-- 		c = {
-- 			a = { "<cmd>Lspsaga code_action<CR>", "Code action" },
-- 			i = { "<cmd>LspInfo<cr>", "Lsp info" },
-- 			I = { "<cmd>LspInstallInfo<CR>", "Lsp install info" },
-- 			d = { "<cmd>Trouble diagnostics toggle<CR>", "Diagnostic" },
-- 			D = { "<cmd>Trouble diagnostics toggle filter.buf=0<CR>", "Diagnostic" },
-- 			o = { "<cmd>Lspsaga outline<CR>", "Outline" },
-- 			-- f = { "<cmd>lua vim.lsp.buf.format{ async = true }<cr>", "Format file" },
-- 			f = { handle_format, "Format file" },
-- 			r = { "<cmd>Lspsaga rename<CR>", "Rename" },
-- 			["["] = {
-- 				["["] = { "<cmd>lua require('lspsaga.diagnostic'):goto_next()<CR>", "Go to Next Error" },
-- 				e = {
-- 					"<cmd>lua require('lspsaga.diagnostic'):goto_next({ severity = vim.diagnostic.severity.ERROR })<CR>",
-- 					"Go to Next Error",
-- 				},
-- 				i = {
-- 					"<cmd>lua require('lspsaga.diagnostic'):goto_next({ severity = vim.diagnostic.severity.INFO })<CR>",
-- 					"Go to Next Info",
-- 				},
-- 				w = {
-- 					"<cmd>lua require('lspsaga.diagnostic'):goto_next({ severity = vim.diagnostic.severity.WARN })<CR>",
-- 					"Go to Next Warning",
-- 				},
-- 			},
-- 			["]"] = {
-- 				["]"] = { "<cmd>lua require('lspsaga.diagnostic'):goto_prev()<CR>", "Go to Next Error" },
-- 				E = {
-- 					"<cmd>lua require('lspsaga.diagnostic'):goto_prev({ severity = vim.diagnostic.severity.ERROR })<CR>",
-- 					"Go to Previous Error",
-- 				},
-- 				W = {
-- 					"<cmd>lua require('lspsaga.diagnostic'):goto_prev({ severity = vim.diagnostic.severity.WARN })<CR>",
-- 					"Go to Previous Warning",
-- 				},
-- 				I = {
-- 					"<cmd>lua require('lspsaga.diagnostic'):goto_prev({ severity = vim.diagnostic.severity.INFO })<CR>",
-- 					"Go to Previous Info",
-- 				},
-- 			},
-- 		},
-- 		d = {
-- 			name = "+Debug",
-- 			t = { "<cmd>lua require'dap'.toggle_breakpoint()<cr>", "Toggle Breakpoint" },
-- 			b = { "<cmd>lua require'dap'.step_back()<cr>", "Step Back" },
-- 			c = { "<cmd>lua require'dap'.continue()<cr>", "Continue" },
-- 			C = { "<cmd>lua require'dap'.run_to_cursor()<cr>", "Run To Cursor" },
-- 			d = { "<cmd>lua require'dap'.disconnect()<cr>", "Disconnect" },
-- 			g = { "<cmd>lua require'dap'.session()<cr>", "Get Session" },
-- 			i = { "<cmd>lua require'dap'.step_into()<cr>", "Step Into" },
-- 			o = { "<cmd>lua require'dap'.step_over()<cr>", "Step Over" },
-- 			u = { "<cmd>lua require'dap'.step_out()<cr>", "Step Out" },
-- 			p = { "<cmd>lua require'dap'.pause()<cr>", "Pause" },
-- 			r = { "<cmd>lua require'dap'.repl.toggle()<cr>", "Toggle Repl" },
-- 			s = { "<cmd>lua require'dap'.continue()<cr>", "Start" },
-- 			q = { "<cmd>lua require'dap'.close()<cr>", "Quit" },
-- 			U = { "<cmd>lua require'dapui'.toggle({reset = true})<cr>", "Toggle UI" },
-- 		},
-- 		e = { nvim_tree_toggle_focus, "NvimTree Toggle & Focus" },
-- 		E = { "<cmd>NvimTreeToggle<CR>", "NvimTree Toggle & Focus" },
-- 		f = {
-- 			name = "+Find",
-- 			a = { "<cmd>Telescope buffers<CR>", "Buffers search" },
-- 			b = { "<cmd>Telescope current_buffer_fuzzy_find<CR>", "Current buffer word search" },
-- 			c = { "<cmd>Telescope git_commits<CR>", "Git commits search" },
-- 			d = { "<cmd>Telescope git_branches<CR>", "Git branches search" },
-- 			e = { "<cmd>Telescope git_status<CR>", "Git diff search" },
-- 			f = { "<cmd>Telescope live_grep<CR>", "word search" },
-- 			h = { "<cmd>Telescope search_history<CR>", "CMD history search" },
-- 			i = {
-- 				"<cmd>lua require('telescope.builtin').lsp_document_symbols({ symbols={'function', 'method', 'constructor'} })<CR>",
-- 				"Document symbols search",
-- 			},
-- 			l = { "<cmd>lua require('telescope.builtin').live_grep({grep_open_files=true})<CR>", "Buffers word search" },
-- 			m = { "<cmd>lua require('telescope.builtin').marks()<CR>", "Buffers word search" },
-- 			p = { "<cmd>Telescope fd fd_command=fd,--hidden,--files prompt_prefix=🔍<CR>", "Files search" },
-- 			s = { "<cmd>Telescope git_stash<CR>", "Git stash search" },
-- 			t = { "<cmd>Telescope tags<CR>", "Tags search" },
-- 		},
-- 		y = { '"+y', "Yank2clipboard" },
-- 		["<space>"] = { "za", "Close Fold" },
-- 	},
-- }
--
local mappings = {
	{
		mode = { "v", "n" },
		-- {
		-- 	"<leader>1",
		-- 	"<cmd>lua require('bufferline').go_to(1, true)<CR>",
		-- 	desc = "Goto Buffer 1",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		-- {
		-- 	"<leader>2",
		-- 	"<cmd>lua require('bufferline').go_to(2, true)<CR>",
		-- 	desc = "Goto Buffer 2",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		-- {
		-- 	"<leader>3",
		-- 	"<cmd>lua require('bufferline').go_to(3, true)<CR>",
		-- 	desc = "Goto Buffer 3",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		-- {
		-- 	"<leader>4",
		-- 	"<cmd>lua require('bufferline').go_to(4, true)<CR>",
		-- 	desc = "Goto Buffer 4",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		-- {
		-- 	"<leader>5",
		-- 	"<cmd>lua require('bufferline').go_to(5, true)<CR>",
		-- 	desc = "Goto Buffer 5",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		-- {
		-- 	"<leader>6",
		-- 	"<cmd>lua require('bufferline').go_to(6, true)<CR>",
		-- 	desc = "Goto Buffer 6",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		-- {
		-- 	"<leader>7",
		-- 	"<cmd>lua require('bufferline').go_to(7, true)<CR>",
		-- 	desc = "Goto Buffer 7",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		-- {
		-- 	"<leader>8",
		-- 	"<cmd>lua require('bufferline').go_to(8, true)<CR>",
		-- 	desc = "Goto Buffer 8",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		-- {
		-- 	"<leader>9",
		-- 	"<cmd>lua require('bufferline').go_to(9, true)<CR>",
		-- 	desc = "Goto Buffer 9",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		{
			"<leader>\\",
			"<cmd>BufferLineCycleNext<CR>",
			desc = "Next Buffer",
			nowait = true,
			remap = false,
		},
		-- { "<leader>d", group = "Delete Buffers", nowait = true, remap = false },
		-- {
		-- 	"<leader>dd",
		-- 	"<cmd>Bdelete %<CR>",
		-- 	desc = "Current",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		-- {
		-- 	"<leader>dl",
		-- 	"<cmd>BufferLineCloseLeft<CR>",
		-- 	desc = "To the Left",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		-- {
		-- 	"<leader>do",
		-- 	"<cmd>BufferLineCloseOthers<CR>",
		-- 	desc = "All but current",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		-- {
		-- 	"<leader>dr",
		-- 	"<cmd>BufferLineCloseRight<CR>",
		-- 	desc = "To the Right",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		{ "<leader>t", group = "ToggleTerm", nowait = true, remap = false },
		{
			"<leader>tg",
			"<cmd>lua _LAZYGIT_TOGGLE()<CR>",
			desc = "Lazygit",
			nowait = true,
			remap = false,
		},
		{
			"<leader>tn",
			"<cmd>lua _NODE_TOGGLE()<CR>",
			desc = "Node",
			nowait = true,
			remap = false,
		},
		{
			"<leader>tp",
			"<cmd>lua _PYTHON_TOGGLE()<CR>",
			desc = "Python",
			nowait = true,
			remap = false,
		},
		{
			"<leader>tr",
			"<cmd>lua _RANGER_TOGGLE()<CR>",
			desc = "Ranger",
			nowait = true,
			remap = false,
		},
		{
			"<leader>tt",
			"<cmd>ToggleTerm<CR>",
			desc = "Terminal",
			nowait = true,
			remap = false,
		},
		{ "<leader>v", group = "Vim", nowait = true, remap = false },
		{
			"<leader>ve",
			"<cmd>vsplit $MYVIMRC<CR>",
			desc = "Edit",
			nowait = true,
			remap = false,
		},
		{
			"<leader>vs",
			"<cmd>source $MYVIMRC<CR>",
			desc = "Source",
			nowait = true,
			remap = false,
		},
		{ "<leader>w", group = "BufferLine", nowait = true, remap = false },
		{
			"<leader>wA",
			"<cmd>BufferLineMoveNext<CR>",
			desc = "Move buffer prev",
			nowait = true,
			remap = false,
		},
		{
			"<leader>wa",
			"<cmd>BufferLineMoveNext<CR>",
			desc = "Move buffer next",
			nowait = true,
			remap = false,
		},
		{
			"<leader>wd",
			"<cmd>BufferLinePickClose<CR>",
			desc = "Delete a buffer",
			nowait = true,
			remap = false,
		},
		{
			"<leader>wp",
			"<cmd>BufferLineTogglePin<CR>",
			desc = "Pin buffer",
			nowait = true,
			remap = false,
		},
		{
			"<leader>ww",
			"<cmd>BufferLinePick<CR>",
			desc = "Pick a buffer",
			nowait = true,
			remap = false,
		},
		{
			"<leader>|",
			"<cmd>BufferLineCyclePrev<CR>",
			desc = "Previous Buffer",
			nowait = true,
			remap = false,
		},
		{
			"<space><space>",
			"za",
			desc = "Close Fold",
			nowait = true,
			remap = false,
		},
		{
			"<space>E",
			"<cmd>NvimTreeToggle<CR>",
			desc = "NvimTree Toggle & Focus",
			nowait = true,
			remap = false,
		},
		-- { "<space>a", group = "Harpooon", nowait = true, remap = false },
		-- {
		-- 	"<space>a1",
		-- 	function()
		-- 		harpoon:list():select(1)
		-- 	end,
		-- 	desc = "Select 1",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		-- {
		-- 	"<space>a2",
		-- 	function()
		-- 		harpoon:list():select(2)
		-- 	end,
		-- 	desc = "Select 2",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		-- {
		-- 	"<space>a3",
		-- 	function()
		-- 		harpoon:list():select(3)
		-- 	end,
		-- 	desc = "Select 3",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		-- {
		-- 	"<space>a4",
		-- 	function()
		-- 		harpoon:list():select(4)
		-- 	end,
		-- 	desc = "Select 4",
		-- 	nowait = true,
		-- 	remap = false,
		-- },
		{
			"<space>cD",
			"<cmd>Trouble diagnostics toggle filter.buf=0<CR>",
			desc = "Diagnostic",
			nowait = true,
			remap = false,
		},
		{ "<space>cI", "<cmd>LspInstallInfo<CR>", desc = "Lsp install info", nowait = true, remap = false },
		{
			"<space>c[[",
			"<cmd>lua require('lspsaga.diagnostic'):goto_next()<CR>",
			desc = "Go to Next Error",
			nowait = true,
			remap = false,
		},
		{
			"<space>c[e",
			"<cmd>lua require('lspsaga.diagnostic'):goto_next({ severity = vim.diagnostic.severity.ERROR })<CR>",
			desc = "Go to Next Error",
			nowait = true,
			remap = false,
		},
		{
			"<space>c[i",
			"<cmd>lua require('lspsaga.diagnostic'):goto_next({ severity = vim.diagnostic.severity.INFO })<CR>",
			desc = "Go to Next Info",
			nowait = true,
			remap = false,
		},
		{
			"<space>c[w",
			"<cmd>lua require('lspsaga.diagnostic'):goto_next({ severity = vim.diagnostic.severity.WARN })<CR>",
			desc = "Go to Next Warning",
			nowait = true,
			remap = false,
		},
		{
			"<space>c]E",
			"<cmd>lua require('lspsaga.diagnostic'):goto_prev({ severity = vim.diagnostic.severity.ERROR })<CR>",
			desc = "Go to Previous Error",
			nowait = true,
			remap = false,
		},
		{
			"<space>c]I",
			"<cmd>lua require('lspsaga.diagnostic'):goto_prev({ severity = vim.diagnostic.severity.INFO })<CR>",
			desc = "Go to Previous Info",
			nowait = true,
			remap = false,
		},
		{
			"<space>c]W",
			"<cmd>lua require('lspsaga.diagnostic'):goto_prev({ severity = vim.diagnostic.severity.WARN })<CR>",
			desc = "Go to Previous Warning",
			nowait = true,
			remap = false,
		},
		{
			"<space>c]]",
			"<cmd>lua require('lspsaga.diagnostic'):goto_prev()<CR>",
			desc = "Go to Next Error",
			nowait = true,
			remap = false,
		},
		{ "<space>ca", "<cmd>Lspsaga code_action<CR>", desc = "Code action", nowait = true, remap = false },
		{ "<space>cd", "<cmd>Trouble diagnostics toggle<CR>", desc = "Diagnostic", nowait = true, remap = false },
		{ "<space>cf", handle_format, desc = "Format file", nowait = true, remap = false },
		{ "<space>ci", "<cmd>LspInfo<cr>", desc = "Lsp info", nowait = true, remap = false },
		{ "<space>co", "<cmd>Lspsaga outline<CR>", desc = "Outline", nowait = true, remap = false },
		{ "<space>cr", "<cmd>Lspsaga rename<CR>", desc = "Rename", nowait = true, remap = false },
		{ "<space>cT", group = "TypeScript Tools", nowait = true, remap = false },
		{ "<space>cTo", "<cmd>TSToolsOrganizeImports<CR>", desc = "Organize imports", nowait = true, remap = false },
		{ "<space>cTa", "<cmd>TSToolsAddMissingImports<CR>", desc = "Add missing imports", nowait = true, remap = false },
		{ "<space>cTu", "<cmd>TSToolsRemoveUnused<CR>", desc = "Remove unused", nowait = true, remap = false },
		{ "<space>cTf", "<cmd>TSToolsFixAll<CR>", desc = "Fix all", nowait = true, remap = false },
		{ "<space>cTd", "<cmd>TSToolsGoToSourceDefinition<CR>", desc = "Go to source definition", nowait = true, remap = false },
		{ "<space>cTr", "<cmd>TSToolsRenameFile<CR>", desc = "Rename file", nowait = true, remap = false },
		{ "<space>cTR", "<cmd>TSToolsFileReferences<CR>", desc = "File references", nowait = true, remap = false },
		{ "<space>cTs", "<cmd>TSToolsSortImports<CR>", desc = "Sort imports", nowait = true, remap = false },
		{ "<space>d", group = "Debug", nowait = true, remap = false },
		{
			"<space>dC",
			"<cmd>lua require'dap'.run_to_cursor()<cr>",
			desc = "Run To Cursor",
			nowait = true,
			remap = false,
		},
		{
			"<space>dU",
			"<cmd>lua require'dapui'.toggle({reset = true})<cr>",
			desc = "Toggle UI",
			nowait = true,
			remap = false,
		},
		{
			"<space>db",
			"<cmd>lua require'dap'.step_back()<cr>",
			desc = "Step Back",
			nowait = true,
			remap = false,
		},
		{
			"<space>dc",
			"<cmd>lua require'dap'.continue()<cr>",
			desc = "Continue",
			nowait = true,
			remap = false,
		},
		{
			"<space>dd",
			"<cmd>lua require'dap'.disconnect()<cr>",
			desc = "Disconnect",
			nowait = true,
			remap = false,
		},
		{
			"<space>dg",
			"<cmd>lua require'dap'.session()<cr>",
			desc = "Get Session",
			nowait = true,
			remap = false,
		},
		{
			"<space>di",
			"<cmd>lua require'dap'.step_into()<cr>",
			desc = "Step Into",
			nowait = true,
			remap = false,
		},
		{
			"<space>dl",
			"<cmd>lua require'dap'.clear_breakpoints()<cr>",
			desc = "Clear all Breakpoints",
			nowait = true,
			remap = false,
		},
		{
			"<space>do",
			"<cmd>lua require'dap'.step_over()<cr>",
			desc = "Step Over",
			nowait = true,
			remap = false,
		},
		{
			"<space>dp",
			"<cmd>lua require'dap'.pause()<cr>",
			desc = "Pause",
			nowait = true,
			remap = false,
		},
		{
			"<space>dq",
			"<cmd>lua require'dap'.close()<cr>",
			desc = "Quit",
			nowait = true,
			remap = false,
		},
		{
			"<space>dr",
			"<cmd>lua require'dap'.repl.toggle()<cr>",
			desc = "Toggle Repl",
			nowait = true,
			remap = false,
		},
		{
			"<space>ds",
			"<cmd>lua require'dap'.continue()<cr>",
			desc = "Start",
			nowait = true,
			remap = false,
		},
		{
			"<space>dt",
			"<cmd>lua require'dap'.toggle_breakpoint()<cr>",
			desc = "Toggle Breakpoint",
			nowait = true,
			remap = false,
		},
		{
			"<space>du",
			"<cmd>lua require'dap'.step_out()<cr>",
			desc = "Step Out",
			nowait = true,
			remap = false,
		},
		{
			"<space>e",
			nvim_tree_toggle_focus,
			desc = "NvimTree Toggle & Focus",
			nowait = true,
			remap = false,
		},
		{ "<space>f", group = "Find", nowait = true, remap = false },
		{
			"<space>fa",
			"<cmd>Telescope buffers<CR>",
			desc = "Buffers search",
			nowait = true,
			remap = false,
		},
		{
			"<space>fb",
			"<cmd>Telescope current_buffer_fuzzy_find<CR>",
			desc = "Current buffer word search",
			nowait = true,
			remap = false,
		},
		{
			"<space>fc",
			"<cmd>Telescope git_commits<CR>",
			desc = "Git commits search",
			nowait = true,
			remap = false,
		},
		{
			"<space>fd",
			"<cmd>Telescope git_branches<CR>",
			desc = "Git branches search",
			nowait = true,
			remap = false,
		},
		{
			"<space>fe",
			"<cmd>Telescope git_status<CR>",
			desc = "Git diff search",
			nowait = true,
			remap = false,
		},
		{
			"<space>ff",
			function() require("plugins.telescope_search").advanced_search() end,
			desc = "Advanced search (C-r: regex, C-t: filetype, C-e: tests)",
			nowait = true,
			remap = false,
		},
		{
			"<space>fh",
			"<cmd>Telescope search_history<CR>",
			desc = "CMD history search",
			nowait = true,
			remap = false,
		},
		{
			"<space>fi",
			"<cmd>lua require('telescope.builtin').lsp_document_symbols({ symbols={'function', 'method', 'constructor'} })<CR>",
			desc = "Document symbols search",
			nowait = true,
			remap = false,
		},
		{
			"<space>fl",
			"<cmd>lua require('telescope.builtin').live_grep({grep_open_files=true})<CR>",
			desc = "Buffers word search",
			nowait = true,
			remap = false,
		},
		{
			"<space>fm",
			"<cmd>lua require('telescope.builtin').marks()<CR>",
			desc = "Buffers word search",
			nowait = true,
			remap = false,
		},
		{
			"<space>fp",
			"<cmd>Telescope fd fd_command=fd,--hidden,--files prompt_prefix=🔍<CR>",
			desc = "Files search",
			nowait = true,
			remap = false,
		},
		{ "<space>fs", "<cmd>Telescope git_stash<CR>", desc = "Git stash search", nowait = true, remap = false },
		{ "<space>ft", "<cmd>Telescope tags<CR>", desc = "Tags search", nowait = true, remap = false },
		{ "<space>t", group = "NeoTest", nowait = true, remap = false },
		{
			"<space>tt",
			"<cmd>lua require('neotest').run.run()<cr>",
			desc = "Test Nearest",
			nowait = true,
			remap = false,
		},
		{
			"<space>tf",
			"<cmd>lua require('neotest').run.run(vim.fn.expand('%'))<cr>",
			desc = "Test File",
			nowait = true,
			remap = false,
		},
		{
			"<space>td",
			"<cmd>lua require('neotest').run.run({ strategy = 'dap' })<cr>",
			desc = "Test Debug (DAP)",
			nowait = true,
			remap = false,
		},
		{
			"<space>to",
			"<cmd>lua require('neotest').output.open({ enter = true, auto_close = true })<cr>",
			desc = "Test Output",
			nowait = true,
			remap = false,
		},
		{
			"<space>ts",
			"<cmd>lua require('neotest').summary.toggle()<cr>",
			desc = "Test Summary",
			nowait = true,
			remap = false,
		},
		{ "<space>m", group = "Markdown", nowait = true, remap = false },
		{
			"<space>mt",
			function()
				require("markview.extras.checkboxes").toggler.init()
			end,
			desc = "Toggle checkbox",
			nowait = true,
			remap = false,
		},
		{
			"<space>mi",
			function()
				require("markview.extras.checkboxes").interactive.init()
			end,
			desc = "Interactive checkbox",
			nowait = true,
			remap = false,
		},
		{
			"<space>mh",
			function()
				require("markview.extras.headings").increase()
			end,
			desc = "Increase heading level",
			nowait = true,
			remap = false,
		},
		{
			"<space>mH",
			function()
				require("markview.extras.headings").decrease()
			end,
			desc = "Decrease heading level",
			nowait = true,
			remap = false,
		},
		{
			"<space>me",
			function()
				require("markview.extras.editor").edit()
			end,
			desc = "Edit code block",
			nowait = true,
			remap = false,
		},
		{
			"<space>mc",
			function()
				require("markview.extras.editor").create()
			end,
			desc = "Create code block",
			nowait = true,
			remap = false,
		},
		{ "<space>y", '"+y', desc = "Yank2clipboard", nowait = true, remap = false },
	},
}

wk.add(mappings)
-- which_key.register(mappings, get_opts("n"))
-- which_key.register(mappings, get_opts("v"))

-- vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter", "BufDelete" }, { callback = get_buffers })
-- local keymap = vim.api.nvim_set_keymap
-- keymap('n','\\',':WhichKey \\<CR>',{ noremap = true, silent = true })
