local status_ok, toggleterm = pcall(require, "toggleterm")
if not status_ok then
	return
end

toggleterm.setup({
	size = 20,
	open_mapping = [[<c-\>]],
	hide_numbers = true,
	shade_filetypes = {},
	shade_terminals = true,
	shading_factor = 2,
	start_in_insert = true,
	insert_mappings = true,
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
	return Terminal:new({ cmd = cmd, hidden = true })
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
    if file~=nil
      then
        vim.cmd("e " .. file:read("*a"))
        file:close()

        os.remove(ranger_tmpfile)
    end
  end,
})
function _RANGER_TOGGLE()
	ranger:toggle()
end
