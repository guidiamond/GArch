local status_ok, trouble = pcall(require, "trouble")
if not status_ok then
	return
end

trouble.setup({
	auto_close = true,
	keys = {
		o = "jump_close",
		["<CR>"] = "jump_close",
		["<TAB>"] = "jump_close",
	},
	focus = true,
})
