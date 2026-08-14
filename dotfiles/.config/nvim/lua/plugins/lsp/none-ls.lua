local null_ls_status_ok, null_ls = pcall(require, "null-ls")
if not null_ls_status_ok then
	return
end

-- https://github.com/jose-elias-alvarez/null-ls.nvim/tree/main/lua/null-ls/builtins/formatting
local formatting = null_ls.builtins.formatting
-- https://github.com/jose-elias-alvarez/null-ls.nvim/tree/main/lua/null-ls/builtins/diagnostics
local diagnostics = null_ls.builtins.diagnostics
-- https://github.com/jose-elias-alvarez/null-ls.nvim/tree/main/lua/null-ls/builtins/code_actions
local code_actions = null_ls.builtins.code_actions

-- Nearest config wins: eslint+prettier only activate when eslint config is
-- closer to the file than any biome config (handles monorepos).
local biome_markers = { "biome.json", "biome.jsonc" }
local eslint_markers = {
	".eslintrc",
	".eslintrc.js",
	".eslintrc.cjs",
	".eslintrc.json",
	".eslintrc.yml",
	".eslintrc.yaml",
	"eslint.config.js",
	"eslint.config.mjs",
	"eslint.config.cjs",
}

local function use_eslint()
	local bufname = vim.api.nvim_buf_get_name(0)
	local eslint_root = vim.fs.root(bufname, eslint_markers)
	local biome_root = vim.fs.root(bufname, biome_markers)

	if eslint_root then
		if not biome_root or #eslint_root > #biome_root then
			return true
		end
	end
	return false
end

null_ls.setup({
	debug = false,
	sources = {
		formatting.prettier.with({ condition = use_eslint }),
		-- formatting.black.with({ extra_args = { "--fast" } }),
		formatting.stylua,
		require("none-ls.code_actions.eslint_d").with({ condition = use_eslint }),
		require("none-ls.diagnostics.eslint_d").with({ condition = use_eslint }),
		require("none-ls.formatting.eslint_d").with({ condition = use_eslint }),
		-- formatting.eslint_d,
		-- formatting.beautysh, -- In addition to Bash, Beautysh can format csh, ksh, sh and zsh.
		-- code_actions.eslint_d,
		-- diagnostics.eslint_d,
		diagnostics.zsh,
		-- diagnostics.mypy, -- Type Checking
		-- diagnostics.ruff, -- Linting
	},
})
