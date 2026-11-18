if vim.g.loaded_claude_fill then
  return
end
vim.g.loaded_claude_fill = true

require('claude_fill.command').register()
