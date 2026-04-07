local status_ok, configs = pcall(require, "nvim-treesitter.configs")
if not status_ok then
	return
end
-- use require('ts_context_commentstring').setup {} and set vim.g.skip_ts_context_commentstring_module = true to speed up loading instead.

configs.setup({
	enable = true,
	ensure_installed = "all", -- one of "all" or a list of languages
	ignore_install = { "" }, -- List of parsers to ignore installing
	indent = { enable = true, disable = { "python", "css" } },
	rainbow = {
		enable = true,
		extended_mode = true, -- Highlight also non-parentheses delimiters, boolean or table: lang -> boolean
		max_file_lines = 1000, -- Do not enable for files with more than 1000 lines, int
	},
	-- context_commentstring = {
	--   enable = true,
	--   enable_autocmd = false, -- Disable autocmd commentstring calculation if you use any comment plugins (they do that for you)
	-- },
	highlight = {
		enable = true, -- false will disable the whole extension
		-- disable = { "css" }, -- list of language that will be disabled
		-- is
	},
})
-- configs.setup({
-- ensure_installed = "all", -- one of "all" or a list of languages
-- ignore_install = { "" }, -- List of parsers to ignore installing
-- 	highlight = {
-- 		enable = true, -- false will disable the whole extension
-- 		disable = { "css" }, -- list of language that will be disabled
-- 	},
-- 	autopairs = {
-- 		enable = true,
-- 	},
-- 	indent = { enable = true, disable = { "python", "css" } },
-- })
--

-- Set folding to treesitter
vim.opt.foldmethod = "expr"
vim.opt.foldexpr = "nvim_treesitter#foldexpr()"
vim.opt.foldenable = false
