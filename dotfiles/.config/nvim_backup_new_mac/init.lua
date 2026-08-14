local status_ok, install_lazy_nvim = pcall(require, "check_install_lazy_nvim.lua")
if not status_ok then
  return
end

install_lazy_nvim.check_install_lazy_nvim()
require('plugins.plugin_manager.lazy_nvim')

-- -- General Configs
-- require('general.options')
-- require('general.colorscheme')
-- -- Plugins
-- require('plugins.plugins')
-- require('plugins.dap')
-- require('plugins.toggleterm')
-- require('plugins.gutentags')
-- require('plugins.quickscope')
-- require('plugins.sneak')
-- require('plugins.telescope')
-- require('plugins.bufferline')
-- require('plugins.lualine')
-- require('plugins.nvim-tree')
-- require('plugins.gitsigns')
-- require('plugins.cmp')
-- require('plugins.lsp')
-- require('plugins.treesitter')
-- -- Key Maps
-- require('keys.mappings')
-- require('keys.whichkey')
