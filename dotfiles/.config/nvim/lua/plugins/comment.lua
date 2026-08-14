local status_ok_comment, comment = pcall(require, "Comment")
if not status_ok_comment then
  return
end

local M = {}

-- Speeds up loading time. Must be set before ts_context_commentstring loads,
-- otherwise it has already registered its autocmd module.
vim.g.skip_ts_context_commentstring_module = true

local status_ok_ts_context_commentstring, ts_context = pcall(require, "ts_context_commentstring")
if status_ok_ts_context_commentstring then
  ts_context.setup {}

  local ts_pre_hook = require('ts_context_commentstring.integrations.comment_nvim').create_pre_hook()

  M['pre_hook'] = function(ctx)
    -- Without a parser the hook returns nil and Comment.nvim falls through to
    -- its own treesitter path, which indexes the nil parser and blows up with
    -- an unhelpful "[Comment.nvim] nil". Bail out to the built-in ft table.
    if not vim.treesitter.get_parser(0, nil, { error = false }) then
      -- Mirror Comment.nvim's own fallback order, skipping only the treesitter
      -- walk. Must never return nil, or it re-enters the crashing path.
      return require('Comment.ft').get(vim.bo.filetype, ctx.ctype) or vim.bo.commentstring
    end
    return ts_pre_hook(ctx)
  end
end

comment.setup(M)

-- Default keybindings:
--
-- NORMAL MODE
--
-- `gcc` - Toggles the current line using linewise comment
-- `gbc` - Toggles the current line using blockwise comment
-- `[count]gcc` - Toggles the number of line given as a prefix-count using linewise
-- `[count]gbc` - Toggles the number of line given as a prefix-count using blockwise
-- `gc[count]{motion}` - (Op-pending) Toggles the region using linewise comment
-- `gb[count]{motion}` - (Op-pending) Toggles the region using blockwise comment
-- `gco` - Insert comment to the next line and enters INSERT mode
-- `gcO` - Insert comment to the previous line and enters INSERT mode
-- `gcA` - Insert comment to end of the current line and enters INSERT mode
--
-- VISUAL MODE
--
-- `gcc` - Toggles the current line using linewise comment
-- `gbc` - Toggles the current line using blockwise comment
-- `[count]gcc` - Toggles the number of line given as a prefix-count using linewise
-- `[count]gbc` - Toggles the number of line given as a prefix-count using blockwise
-- `gc[count]{motion}` - (Op-pending) Toggles the region using linewise comment
-- `gb[count]{motion}` - (Op-pending) Toggles the region using blockwise comment
