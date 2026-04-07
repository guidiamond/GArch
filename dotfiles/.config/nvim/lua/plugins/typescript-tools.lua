local status_ok, typescript_tools = pcall(require, "typescript-tools")

if not status_ok then
	return
end

local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities.textDocument.completion.completionItem.snippetSupport = true
local cmp_ok, cmp_nvim_lsp = pcall(require, "cmp_nvim_lsp")
if cmp_ok then
	capabilities = cmp_nvim_lsp.default_capabilities(capabilities)
end

typescript_tools.setup({
	on_attach = function(client)
		-- Disable formatting so biome/prettier handle it instead
		client.server_capabilities.documentFormattingProvider = false
		client.server_capabilities.documentRangeFormattingProvider = false
	end,
	capabilities = capabilities,
	settings = {
		separate_diagnostic_server = true,
		publish_diagnostic_on = "insert_leave",
		tsserver_max_memory = "auto",
		complete_function_calls = false,
		code_lens = "off",
		jsx_close_tag = {
			enable = false,
		},
	},
})
