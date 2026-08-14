local status_ok, ts = pcall(require, "nvim-treesitter")
if not status_ok then
	return
end

-- The `main` branch dropped the module system (`nvim-treesitter.configs`), so
-- highlight/indent/fold are enabled through Neovim's own treesitter API below
-- and parsers are installed with `install()` instead of `ensure_installed`.
ts.setup({
	install_dir = vim.fn.stdpath("data") .. "/site",
})

-- Swap for { "all" } to grab every parser nvim-treesitter knows about, at the
-- cost of compiling 300+ of them locally.
ts.install({
	"bash",
	"c",
	"css",
	"diff",
	"dockerfile",
	"gitcommit",
	"gitignore",
	"go",
	"graphql",
	"hcl",
	"html",
	"javascript",
	"jsdoc",
	"json",
	"json5",
	"lua",
	"luadoc",
	"make",
	"markdown",
	"markdown_inline",
	"prisma",
	"python",
	"query",
	"regex",
	"rust",
	"scss",
	"sql",
	"terraform",
	"toml",
	"tsx",
	"typescript",
	"vim",
	"vimdoc",
	"yaml",
})

-- Treesitter indent is still flagged experimental upstream, so keep the same
-- opt-outs the old `indent.disable` list had.
local indent_disabled = { python = true, css = true }

vim.api.nvim_create_autocmd("FileType", {
	group = vim.api.nvim_create_augroup("treesitter_start", { clear = true }),
	callback = function(ev)
		local lang = vim.treesitter.language.get_lang(ev.match)
		if not lang or not pcall(vim.treesitter.start, ev.buf, lang) then
			return
		end

		if not indent_disabled[ev.match] then
			vim.bo[ev.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
		end

		-- Window-local options only apply to the window we're actually in.
		if ev.buf == vim.api.nvim_get_current_buf() then
			vim.wo[0][0].foldmethod = "expr"
			vim.wo[0][0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
		end
	end,
})

vim.opt.foldenable = false
