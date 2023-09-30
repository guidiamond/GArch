local set = vim.g

local colorscheme = "onedark"

local status_ok, _ = pcall(vim.cmd, "colorscheme onedark")
if not status_ok then
  return
end

set.onedark_terminal_italics = 1
