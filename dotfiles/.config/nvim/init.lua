vim.loader.enable() -- Enables `lua-loader`, a builtin Lua module which byte-compiles and caches Lua files (speeds up load times).
if vim.g.vscode then
  require('vscode')
  -- VSCode extension
else
  require("general.options")
  require("plugins.plugin_manager")
  require("keys.mappings")
  -- ordinary Neovim
end
