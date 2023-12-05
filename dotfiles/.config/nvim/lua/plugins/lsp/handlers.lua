local M = {}

local status_cmp_ok, cmp_nvim_lsp = pcall(require, "cmp_nvim_lsp")
if not status_cmp_ok then
  return
end

M.capabilities = vim.lsp.protocol.make_client_capabilities()
M.capabilities.textDocument.completion.completionItem.snippetSupport = true
M.capabilities = cmp_nvim_lsp.default_capabilities(M.capabilities)

M.setup = function()
  local signs = {
    { name = "DiagnosticSignError", text = "" },
    { name = "DiagnosticSignWarn", text = "" },
    { name = "DiagnosticSignHint", text = "" },
    { name = "DiagnosticSignInfo", text = "" },
  }

  for _, sign in ipairs(signs) do
    vim.fn.sign_define(sign.name, { texthl = sign.name, text = sign.text, numhl = "" })
  end

  vim.diagnostic.config({
    virtual_text = false, -- disable virtual text
    -- virtual_text = {
    -- 	-- source = "always",  -- Or "if_many"
    -- 	prefix = "●", -- Could be '■', '▎', 'x'
    -- },
    signs = {
      active = signs, -- show signs
    },
    update_in_insert = true,
    underline = true,
    severity_sort = true,
    float = {
      focusable = true,
      style = "minimal",
      border = "rounded",
      source = "always",
      header = "",
      prefix = "",
    },
  })

  vim.lsp.handlers["textDocument/hover"] = vim.lsp.with(vim.lsp.handlers.hover, {
    border = "rounded",
  })

  vim.lsp.handlers["textDocument/signatureHelp"] = vim.lsp.with(vim.lsp.handlers.signature_help, {
    border = "rounded",
  })
end

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
  keymap(bufnr, "n", "gr", "<cmd>lua vim.lsp.buf.references()<CR>", opts)
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

M.on_attach = function(client, bufnr)
  lsp_keymaps(bufnr)
  local status_ok, illuminate = pcall(require, "illuminate")
  if not status_ok then
    return
  end
  illuminate.on_attach(client)
end

return M
