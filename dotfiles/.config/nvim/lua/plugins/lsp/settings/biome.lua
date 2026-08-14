local biome_markers = { "biome.json", "biome.jsonc" }
local eslint_markers = {
	".eslintrc",
	".eslintrc.js",
	".eslintrc.json",
	".eslintrc.yml",
	".eslintrc.yaml",
	"eslint.config.js",
	"eslint.config.mjs",
	"eslint.config.cjs",
}

return {
	root_dir = function(bufnr, cb)
		local fname = vim.api.nvim_buf_get_name(bufnr)
		local biome_root = vim.fs.root(fname, biome_markers)
		local eslint_root = vim.fs.root(fname, eslint_markers)

		-- If eslint config is found closer to the file than biome config,
		-- eslint owns this file — don't start biome LSP
		if eslint_root and biome_root and #eslint_root > #biome_root then
			cb(nil)
			return
		end

		cb(biome_root)
	end,
}
