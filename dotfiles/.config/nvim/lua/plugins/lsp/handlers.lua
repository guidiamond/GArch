local M = {}

local function lsp_keymaps(bufnr)
	local opts = { noremap = true, silent = true }
	local keymap = vim.api.nvim_buf_set_keymap
	keymap(bufnr, "n", "gD", "<cmd>lua vim.lsp.buf.declaration()<CR>", opts)
	-- keymap(bufnr, "n", "gd", "<cmd>lua vim.lsp.buf.definition()<CR>", opts)
	keymap(bufnr, "n", "gd", "<cmd>Lspsaga goto_definition<CR>", opts)
	keymap(bufnr, "n", "gt", "<cmd>Lspsaga goto_type_definition<CR>", opts)
	-- keymap(bufnr, "n", "K", "<cmd>lua vim.lsp.buf.hover()<CR>", opts)
	keymap(bufnr, "n", "K", "<cmd>Lspsaga hover_doc<CR>", opts)
	keymap(bufnr, "n", "gI", "<cmd>lua vim.lsp.buf.implementation()<CR>", opts)
	-- keymap(bufnr, "n", "gr", "<cmd>lua vim.lsp.buf.references()<CR>", opts)
	-- keymap(bufnr, "n", "gf", "<cmd>lua vim.diagnostic.open_float()<CR>", opts)
	keymap(bufnr, "n", "gf", "<cmd>Lspsaga show_line_diagnostics<cr>", opts)
	-- keymap(bufnr, "n", "<space>co", "<cmd>lua vim.lsp.buf.format{ async = true }<cr>", opts)
	-- keymap(bufnr, "n", "<space>ci", "<cmd>LspInfo<cr>", opts)
	-- keymap(bufnr, "n", "<space>cI", "<cmd>LspInstallInfo<cr>", opts)
	-- keymap(bufnr, "n", "<space>ca", "<cmd>lua vim.lsp.buf.code_action()<cr>", opts)
	-- keymap(bufnr, "n", "<space>c[", "<cmd>lua vim.diagnostic.goto_next({buffer=0})<cr>", opts)
	-- keymap(bufnr, "n", "<space>c]", "<cmd>lua vim.diagnostic.goto_prev({buffer=0})<cr>", opts)
	-- keymap(bufnr, "n", "<space>cr", "<cmd>lua vim.lsp.buf.rename()<cr>", opts)
	-- keymap(bufnr, "n", "<space>ls", "<cmd>lua vim.lsp.buf.signature_help()<CR>", opts)
	-- keymap(bufnr, "n", "<leader>lq", "<cmd>lua vim.diagnostic.setloclist()<CR>", opts)
end

local format_augroup = vim.api.nvim_create_augroup("LspFormatting", {})

--- Filter that picks the right formatter: biome > null-ls > ruff.
--- Reused by format-on-save and manual format keybindings.
local formatting_blocklist = { "typescript-tools", "ts_ls" }
M.format_filter = function(fmt_client, bufnr)
	for _, blocked in ipairs(formatting_blocklist) do
		if fmt_client.name == blocked then
			return false
		end
	end
	local biome_clients = vim.lsp.get_clients({ bufnr = bufnr, name = "biome" })
	if #biome_clients > 0 then
		return fmt_client.name == "biome"
	end
	local null_ls_clients = vim.lsp.get_clients({ bufnr = bufnr, name = "null-ls" })
	if #null_ls_clients > 0 then
		return fmt_client.name == "null-ls"
	end
	-- Fallback: allow any formatter (e.g. ruff for python)
	return true
end

M.setup = function()
	vim.diagnostic.config({
		virtual_text = false,
		signs = {
			text = {
				[vim.diagnostic.severity.ERROR] = "󰅚",
				[vim.diagnostic.severity.WARN] = "󰀪",
				[vim.diagnostic.severity.INFO] = "󰋽",
				[vim.diagnostic.severity.HINT] = "󰌶",
			},
		},
		update_in_insert = true,
		underline = true,
		severity_sort = true,
		float = {
			focusable = true,
			style = "minimal",
			border = "rounded",
			source = true,
			header = "",
			prefix = "",
		},
	})

	-- vim.lsp.with() was deprecated in nvim 0.12; manually merge border config instead
	vim.lsp.handlers["textDocument/hover"] = function(err, result, ctx, config)
		return vim.lsp.handlers.hover(err, result, ctx, vim.tbl_deep_extend("force", config or {}, { border = "rounded" }))
	end

	vim.lsp.handlers["textDocument/signatureHelp"] = function(err, result, ctx, config)
		return vim.lsp.handlers.signature_help(err, result, ctx, vim.tbl_deep_extend("force", config or {}, { border = "rounded" }))
	end

	-- LspAttach autocmd (replaces the old on_attach callback)
	vim.api.nvim_create_autocmd("LspAttach", {
		callback = function(ev)
			local client = vim.lsp.get_client_by_id(ev.data.client_id)
			local bufnr = ev.buf

			lsp_keymaps(bufnr)

			-- Format on save
			if client and client:supports_method("textDocument/formatting") then
				vim.api.nvim_clear_autocmds({ group = format_augroup, buffer = bufnr })
				vim.api.nvim_create_autocmd("BufWritePre", {
					group = format_augroup,
					buffer = bufnr,
					callback = function()
						-- Check if any formatter passes the filter before calling format
						local formatters = vim.lsp.get_clients({
							bufnr = bufnr,
							method = "textDocument/formatting",
						})
						local has_formatter = false
						for _, fmt_client in ipairs(formatters) do
							if M.format_filter(fmt_client, bufnr) then
								has_formatter = true
								break
							end
						end
						if not has_formatter then
							return
						end

						local formatter_name = "unknown"
						local start = vim.uv.hrtime()
						vim.lsp.buf.format({
							async = false,
							bufnr = bufnr,
							filter = function(fmt_client)
								local ok = M.format_filter(fmt_client, bufnr)
								if ok then
									formatter_name = fmt_client.name
								end
								return ok
							end,
						})
						local elapsed_ms = (vim.uv.hrtime() - start) / 1e6
						vim.notify(
							string.format("Format on save [%s]: %.0fms", formatter_name, elapsed_ms),
							vim.log.levels.INFO
						)
					end,
				})
			end

			local status_ok, illuminate = pcall(require, "illuminate")
			if not status_ok then
				return
			end
			-- vim-illuminate uses deprecated client.supports_method (dot syntax)
			-- suppress the warning until the plugin is updated upstream
			local orig_deprecate = vim.deprecate
			vim.deprecate = function() end
			illuminate.on_attach(client)
			vim.deprecate = orig_deprecate
		end,
	})
end

return M
