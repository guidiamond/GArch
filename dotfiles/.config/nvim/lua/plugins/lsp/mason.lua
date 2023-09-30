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
    automatic_installation = true,
  })
  return true
end

local function setup_lspconfig()
  local lspconfig_status_ok, lspconfig = pcall(require, "lspconfig")
  if not lspconfig_status_ok then
    return false
  end

  local servers = {
    "lua_ls",
    "tsserver",
    "pyright",
    "jsonls",
    -- "cssls",
    -- "html",
    -- "bashls",
    -- "yamlls",
  }

  local opts = {}

  for _, server in pairs(servers) do
    opts = {
      on_attach = require("plugins.lsp.handlers").on_attach,
      capabilities = require("plugins.lsp.handlers").capabilities,
    }

    server = vim.split(server, "@")[1]

    -- Set custom configs for server
    local require_ok, conf_opts = pcall(require, "plugins.lsp.settings." .. server)
    if require_ok then
      opts = vim.tbl_deep_extend("force", conf_opts, opts)
    end

    lspconfig[server].setup(opts)
  end

  return true
end

-- Runs setup_mason -> setup_mason_lspconfig -> setup_lspconfig
local function setup()
  local throw_err = vim.api.nvim_err_writeln

  if not setup_mason() then
    throw_err('Failure in setup_mason!')
  end
  if not setup_mason_lspconfig() then
    throw_err('Failure in setup_mason_lspconfig!')
  end
  if not setup_lspconfig() then
    throw_err('Failure in setup_lspconfig!')
    return true
    end
end

setup()
