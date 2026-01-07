---@diagnostic disable: inject-field
local fs = require("luarocks.fs")
local dir = require("luarocks.dir")
local path = require("luarocks.path")
local util = require("luarocks.util")
local cfg = require("luarocks.core.cfg")

local treesitter_parser = {}

---@class RockSpec
---@field name string
---@field version string
---@field build BuildSpec
---@field variables table

---@class BuildSpec
---@field type string

---@class TreeSitterRockSpec: RockSpec
---@field type fun():string
---@field build TreeSitterBuildSpec

---@class TreeSitterBuildSpec: BuildSpec
---@field lang string
---@field parser? boolean
---@field libflags? string[]
---@field generate? boolean
---@field generate_from_json? boolean
---@field location? string
---@field queries? table<string, string>

--- Run a command displaying its execution on standard output.
-- @return boolean: true if command succeeds (status code 0), false
-- otherwise.
local function execute(...)
	io.stdout:write(table.concat({ ... }, " ") .. "\n")
	return fs.execute(...)
end

---@param rockspec table
function treesitter_parser.run(rockspec, no_install)
	---@cast rockspec RockSpec
	assert(rockspec.build.type == "treesitter-parser" or rockspec.build.type == "tree-sitter")
	---@cast rockspec TreeSitterRockSpec

	local build = rockspec.build

	local build_parser = build.parser == nil or build.parser

	local node_available = false

	-- TODO Make sure tree-sitter CLI version >= 0.22.2
	if not fs.is_tool_available("tree-sitter", "tree-sitter CLI") then
		return nil,
			"'tree-sitter CLI' is not installed.\n" .. rockspec.name .. " requires the tree-sitter CLI to build.\n"
	end
	if build.generate then
		local js_runtime = os.getenv("TREE_SITTER_JS_RUNTIME") or "node"
		local js_runtime_name = js_runtime == "node" and "Node JS" or js_runtime
		if fs.is_tool_available(js_runtime, js_runtime_name) then
			node_available = true
		else
			util.printout("Not able to find node, will attempt to build from grammar.json instead...")
		end
	end
	if build.generate then
		local cmd
		cmd = { "tree-sitter", "generate" }
		local abi = os.getenv("TREE_SITTER_LANGUAGE_VERSION")
		if abi then
			table.insert(cmd, "--abi")
			table.insert(cmd, abi)
		end
		if node_available == false or build.generate_from_json then
			local src_dir = build.location and dir.path(build.location, "src") or "src"
			table.insert(cmd, dir.path(src_dir, "grammar.json"))
		elseif build.location then
			table.insert(cmd, dir.path(build.location, "grammar.js"))
		end
		util.printout("Generating tree-sitter sources...")
		local cmd_str = table.concat(cmd, " ")
		util.printout(cmd_str)
		if not fs.execute(cmd_str) then
			local err = [[
Failed to generate tree-sitter grammar.
See the build output for details.
Note: tree-sitter 0.20.0 or later is required to generate a tree-sitter grammar.
]]
			if node_available == false then
				err = err
					+ [[\n
Note: this grammar _may_ generate if node is installed and/or
using a version of tree-sitter that matches what was used when the grammar was generated.
]]
			end
			return nil, err
		end
		util.printout("Done.")
	end
	if build.queries then
		if fs.is_dir("queries") then
			pcall(fs.delete, "queries")
		end
		fs.make_dir("queries")
		if not fs.exists("queries") then
			return nil, "Could not create directory: queries"
		end
		local queries_dir = dir.path("queries", build.lang)
		fs.make_dir(queries_dir)
		if not fs.exists(queries_dir) then
			return nil, "Could not create directory: " .. queries_dir
		end
		for name, content in pairs(build.queries) do
			local queries_file = fs.absolute_name(dir.path(queries_dir, name))
			local fd = io.open(queries_file, "w+")
			if not fd then
				return nil, "Could not open " .. queries_file .. " for writing"
			end
			fd:write(content)
			fd:close()
		end
		rockspec.build.copy_directories = rockspec.build.copy_directories or {}
		table.insert(rockspec.build.copy_directories, "queries")
	end
	local lib_dir = path.lib_dir(rockspec.name, rockspec.version)
	local parser_dir = no_install and "luarocks_build" or dir.path(lib_dir, "parser")
	local ok, err
	if build_parser then
		local parser_lib = rockspec.build.lang .. "." .. cfg.lib_extension
		if fs.is_tool_available("tree-sitter", "tree-sitter CLI") then
			-- Try tree-sitter build first
			fs.make_dir(parser_dir)
			local parser_lib_path = dir.path(parser_dir, parser_lib)
			local src_dir = build.location and build.location or fs.current_dir()
			ok = execute("tree-sitter", "build", "-o", parser_lib_path, src_dir) and fs.exists(parser_lib_path)
		end
		if not ok then
			err = [[
'tree-sitter build' failed.
See the build output for details.
Note: tree-sitter 0.22.2 or later is required to build this parser.
]]
		end
		pcall(function()
			local dsym_file = dir.absolute_name(dir.path(parser_dir, parser_lib .. ".dSYM"))
			if fs.exists(dsym_file) or fs.is_dir(dsym_file) then
				-- Try to remove macos debug symbols if they exist
				fs.delete(dsym_file)
			end
		end)
	else
		ok = true
	end
	if ok and fs.exists(parser_dir) then
		-- For neovim plugin managers that do not symlink parser_dir to the rtp
		local dest = dir.path(path.install_dir(rockspec.name, rockspec.version), "parser")
		fs.make_dir(dest)
		for _, src in pairs(fs.list_dir(parser_dir)) do
			if src:find("%.so$") ~= nil or src:find("%.dll$") ~= nil then
				fs.copy(dir.path(parser_dir, src), dest)
			end
		end
	end
	return ok, err
end

return treesitter_parser
