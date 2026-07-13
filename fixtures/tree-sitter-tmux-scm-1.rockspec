local modrev = 'scm'
local specrev = '1'

local repo_url = 'https://github.com/Freed-Wu/tree-sitter-tmux'

rockspec_format = '3.0'
package = 'tree-sitter-tmux'
if modrev:sub(1, 1) == '$' then
  modrev = "scm"
  specrev = "1"
  repo_url = "https://github.com/Freed-Wu/tree-sitter-tmux"
  package = repo_url:match("/([^/]+)/?$")
end
version = modrev ..'-'.. specrev

dependencies = { "lua >= 5.1" }

source = {
  url = repo_url:gsub('https', 'git')
}

build = {
  type = "treesitter-parser",
  lang = "tmux",
}
