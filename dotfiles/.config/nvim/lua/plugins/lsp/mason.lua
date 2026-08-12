local servers = {
	"biome",
	"lua_ls",
	-- "ts_ls", -- Replaced by typescript-tools.nvim
	"ruff",
	"pyright",
	"jsonls",
	"terraformls",
	-- "cssls",
	-- "html",
	-- "bashls",
	-- "yamlls",
}

local function setup_mason()
	local status_ok_mason, mason = pcall(require, "mason")
	if not status_ok_mason then
		return false
	end
	mason.setup({
		ui = {
			border = "none",
			icons = {
				package_installed = "◍",
				package_pending = "◍",
				package_uninstalled = "◍",
			},
		},
		log_level = vim.log.levels.INFO,
		max_concurrent_installers = 4,
	})
	return true
end

local function setup_mason_lspconfig()
	local status_ok_mason_lspconfig, mason_lspconfig = pcall(require, "mason-lspconfig")
	if not status_ok_mason_lspconfig then
		return false
	end
	mason_lspconfig.setup({
		ensure_installed = servers,
		-- Only enable the servers we explicitly list below; we call
		-- vim.lsp.enable() ourselves in setup_lsp (mason-lspconfig v2)
		automatic_enable = false,
	})
	return true
end

local function setup_lsp()
	-- Shared capabilities for all servers
	local capabilities = vim.lsp.protocol.make_client_capabilities()
	capabilities.textDocument.completion.completionItem.snippetSupport = true
	local cmp_ok, cmp_nvim_lsp = pcall(require, "cmp_nvim_lsp")
	if cmp_ok then
		capabilities = cmp_nvim_lsp.default_capabilities(capabilities)
	end

	-- Pin all servers to UTF-16 so they don't disagree with typescript-tools/
	-- none-ls (biome otherwise negotiates UTF-8) on the same buffer
	capabilities.general = capabilities.general or {}
	capabilities.general.positionEncodings = { "utf-16" }

	vim.lsp.config("*", {
		capabilities = capabilities,
	})

	-- Apply per-server custom settings
	for _, server in ipairs(servers) do
		server = vim.split(server, "@")[1]

		local require_ok, conf_opts = pcall(require, "plugins.lsp.settings." .. server)
		if require_ok then
			vim.lsp.config(server, conf_opts)
		end
	end

	-- Enable all servers
	vim.lsp.enable(servers)
	return true
end

-- Runs setup_mason -> setup_mason_lspconfig -> setup_lsp
local function setup()
	local throw_err = vim.api.nvim_err_writeln

	if not setup_mason() then
		throw_err("Failure in setup_mason!")
	end
	if not setup_mason_lspconfig() then
		throw_err("Failure in setup_mason_lspconfig!")
	end
	if not setup_lsp() then
		throw_err("Failure in setup_lsp!")
	end
end

setup()
