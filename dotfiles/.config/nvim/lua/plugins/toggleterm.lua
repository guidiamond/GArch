local status_ok, toggleterm = pcall(require, "toggleterm")
if not status_ok then
	return
end

toggleterm.setup({
	size = 20,
	-- open_mapping = [[<leader>tt]],
	hide_numbers = true,
	shade_filetypes = {},
	shade_terminals = true,
	shading_factor = 2,
	-- start_in_insert = true,
	-- insert_mappings = true,
	persist_size = true,
	direction = "float",
	close_on_exit = true,
	shell = vim.o.shell,
	float_opts = {
		border = "curved",
		winblend = 0,
		highlights = {
			border = "Normal",
			background = "Normal",
		},
	},
})

local Terminal = require("toggleterm.terminal").Terminal

local function gen_cmd(cmd)
	return Terminal:new({ cmd = cmd, hidden = true, count = 5 })
end

local lazygit = gen_cmd("lazygit")
function _LAZYGIT_TOGGLE()
	lazygit:toggle()
end

local node = gen_cmd("node")
function _NODE_TOGGLE()
	node:toggle()
end

local ranger_tmpfile = vim.fn.tempname()
local ranger = Terminal:new({
	cmd = 'ranger --choosefiles="' .. ranger_tmpfile .. '"',
	hidden = true,
	on_close = function(term)
		local file = io.open(ranger_tmpfile, "r")
		if file == nil then
			return
		end
		local name = file:read("*a")
		file:close()
		os.remove(ranger_tmpfile)
		local timer = vim.loop.new_timer()
		timer:start(
			0,
			0,
			vim.schedule_wrap(function()
				vim.cmd("edit " .. name)
			end)
		)
	end,
})

function _RANGER_TOGGLE()
	ranger:toggle()
end

function _G.set_terminal_keymaps()
	local opts = { buffer = 0 }
	-- vim.keymap.set("t", "<esc>", [[<C-\><C-n>]], opts)
	vim.keymap.set("t", "<leader>tg", "<cmd>lua _LAZYGIT_TOGGLE()<CR>", opts)
	vim.keymap.set("t", "<leader>tn", "<cmd>lua _NODE_TOGGLE()<CR>", opts)
	vim.keymap.set("t", "<leader>tr", "<cmd>lua _RANGER_TOGGLE()<CR>", opts)
	vim.keymap.set("t", "<leader>tt", "<cmd>ToggleTerm<CR>", opts)
	-- vim.keymap.set("t", "jk", [[<C-\><C-n>]], opts)
	-- vim.keymap.set("t", "<C-h>", [[<Cmd>wincmd h<CR>]], opts)
	-- vim.keymap.set("t", "<C-j>", [[<Cmd>wincmd j<CR>]], opts)
	-- vim.keymap.set("t", "<C-k>", [[<Cmd>wincmd k<CR>]], opts)
	-- vim.keymap.set("t", "<C-l>", [[<Cmd>wincmd l<CR>]], opts)
	-- vim.keymap.set("t", "<C-w>", [[<C-\><C-n><C-w>]], opts)
end

-- if you only want these mappings for toggle term use term://*toggleterm#* instead
vim.cmd("autocmd! TermOpen term://* lua set_terminal_keymaps()")
