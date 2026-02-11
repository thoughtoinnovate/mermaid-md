if vim.g.loaded_mermaid_inline == 1 then
  return
end
vim.g.loaded_mermaid_inline = 1

require("mermaid_inline").setup()
