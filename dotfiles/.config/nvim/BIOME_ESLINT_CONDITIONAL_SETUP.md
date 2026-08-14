# Biome / ESLint+Prettier Conditional Setup

Conditional formatter/linter selection based on project config proximity.
Uses a "nearest config wins" strategy for monorepo support.

## How it works

When opening a file, Neovim searches upward from the file for both `biome.json`
and eslint config files. Whichever config is **closer** (deeper in the directory
tree) to the file wins:

- **Biome config closer** (or no eslint config) -> biome LSP handles formatting,
  linting, and code actions
- **ESLint config closer** (or no biome config) -> eslint_d + prettier via
  none-ls handle everything

### Monorepo example

```
root/
  biome.json                      <- root biome config
  packages/
    frontend/
      .eslintrc.js                <- eslint is closer -> uses eslint+prettier
    package-a/
      biome.json                  <- biome is closer -> uses biome
    package-b/
      biome.json                  <- biome is closer -> uses biome
```

## Files changed

### 1. `lua/plugins/lsp/settings/biome.lua` (NEW)

Biome LSP settings. Custom `root_dir` that returns `nil` (preventing biome from
attaching) when an eslint config is found closer to the file than the biome config.

**To revert:** Delete this file.

### 2. `lua/plugins/lsp/mason.lua`

Added `"biome"` to the `servers` list in `setup_lspconfig()`.

**To revert:** Remove `"biome"` from the servers table.

### 3. `lua/plugins/lsp/none-ls.lua`

Two changes:

1. **Added `use_eslint` condition function** — compares proximity of eslint vs
   biome configs. Returns `true` only when eslint config is closer.

2. **Added `condition = use_eslint`** to all eslint_d and prettier sources so
   they only activate in eslint-configured projects.

3. **Removed `on_attach`** — format-on-save moved to `handlers.lua` (see below).
   Also removed the separate `BufWritePre` autocmd for Python files since
   `handlers.lua` now covers all formatters.

**To revert:** Restore the original sources without `.with({ condition = ... })`
and add back the on_attach with format-on-save:

```lua
local augroup = vim.api.nvim_create_augroup("LspFormatting", {})

-- (inside null_ls.setup)
on_attach = function(client, bufnr)
    if client.supports_method("textDocument/formatting") then
        vim.api.nvim_clear_autocmds({ group = augroup, buffer = bufnr })
        vim.api.nvim_create_autocmd("BufWritePre", {
            group = augroup,
            buffer = bufnr,
            callback = function()
                vim.lsp.buf.format({ async = false, bufnr = bufnr })
            end,
        })
    end
end,

-- And add back the python autocmd after null_ls.setup():
vim.api.nvim_create_autocmd("BufWritePre", {
    pattern = "*.py",
    callback = function()
        vim.lsp.buf.format({ async = false })
    end,
})
```

### 4. `lua/plugins/lsp/handlers.lua`

Centralized format-on-save and format filter logic:

1. **Added `M.format_filter`** — shared filter function that picks the right
   formatter: biome > null-ls > fallback (e.g. ruff for python). Exported so
   whichkey can reuse it.

2. **Added format-on-save autocmd in `on_attach`** — fires for ANY LSP that
   supports `textDocument/formatting` (biome, null-ls, ruff, etc.), using the
   filter above. This replaces the previous autocmd in none-ls.

**To revert:** Remove the `format_augroup`, `M.format_filter`, and the
format-on-save autocmd block from `on_attach`. Restore the original:

```lua
M.on_attach = function(client, bufnr)
    lsp_keymaps(bufnr)
    local status_ok, illuminate = pcall(require, "illuminate")
    if not status_ok then
        return
    end
    illuminate.on_attach(client)
end
```

### 5. `lua/keys/whichkey.lua`

Updated `handle_format()` to use the shared `format_filter` from `handlers.lua`,
so manual format (`<space>cf`) picks the same formatter as format-on-save.

**To revert:** Restore the original `handle_format`:

```lua
local function handle_format()
    local filetype = vim.bo.filetype
    if filetype ~= "json" and filetype ~= "jsonc" then
        vim.lsp.buf.format({ async = true })
    else
        vim.cmd("syntax off")
        vim.lsp.buf.format()
        vim.cmd("syntax on")
    end
end
```

## Debugging

Run `:LspInfo` to see which LSP servers are attached to the current buffer.
In a biome project you should see `biome`; in an eslint project you should not.

Run `:NullLsInfo` to see which none-ls sources are active for the current
buffer. In a biome project, prettier/eslint_d should not appear.
