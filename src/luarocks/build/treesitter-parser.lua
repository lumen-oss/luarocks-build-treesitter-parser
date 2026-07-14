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

---@param build TreeSitterBuildSpec
---@return boolean ok
---@return string? error
local function generate_grammar(build)
	if not build.generate then
		return true
	end
	local node_available = false
	local js_runtime = os.getenv("TREE_SITTER_JS_RUNTIME") or "node"
	local js_runtime_name = js_runtime == "node" and "Node JS" or js_runtime
	if fs.is_tool_available(js_runtime, js_runtime_name) then
		node_available = true
	else
		util.printout("Not able to find node, will attempt to build from grammar.json instead...")
	end
	local cmd = { "tree-sitter", "generate" }
	local abi = os.getenv("TREE_SITTER_LANGUAGE_VERSION")
	if abi then
		table.insert(cmd, "--abi")
		table.insert(cmd, abi)
	end
	if not node_available or build.generate_from_json then
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
		if not node_available then
			err = err
				+ [[\n
Note: this grammar _may_ generate if node is installed and/or
using a version of tree-sitter that matches what was used when the grammar was generated.
]]
		end
		return false, err
	end
	util.printout("Done.")
	return true
end

---@param filename string
---@return boolean
local function is_query_file(filename)
	return filename:find("%.scm$") ~= nil
end

--- Move all query files from `source_dir` into `target_dir`.
---@param source_dir string directory containing query files
---@param target_dir string destination directory (created if it does not exist)
---@return boolean ok
---@return string? error
local function move_query_files(source_dir, target_dir)
	fs.make_dir(target_dir)
	if not fs.exists(target_dir) then
		return false, "Could not create directory: " .. target_dir
	end
	for _, filename in pairs(fs.list_dir(source_dir)) do
		if is_query_file(filename) then
			local source_file = fs.absolute_name(dir.path(source_dir, filename))
			if fs.exists(source_file) then
				fs.copy(source_file, dir.path(target_dir, filename))
				fs.delete(source_file)
			end
		end
	end
	return true
end

---@param dir_name string
---@param name string
---@param content string
---@return boolean ok
---@return string? error
local function write_query(dir_name, name, content)
	local queries_file = fs.absolute_name(dir.path(dir_name, name))
	local fd = io.open(queries_file, "w+")
	if not fd then
		return false, "Could not open " .. queries_file .. " for writing"
	end
	fd:write(content)
	fd:close()
	return true
end

---@param dir_name string
---@param queries table<string, string>
---@return boolean ok
---@return string? error
local function write_queries(dir_name, queries)
	for name, content in pairs(queries) do
		local ok, err = write_query(dir_name, name, content)
		if not ok then
			return false, err
		end
	end
	return true
end

---@param rockspec TreeSitterRockSpec
---@return boolean ok
---@return string? error
local function install_inline_queries(rockspec)
	local build = rockspec.build
	local queries_dir = dir.path("queries", build.lang)
	if fs.is_dir("queries") then
		pcall(fs.delete, "queries")
	end
	fs.make_dir("queries")
	if not fs.exists("queries") then
		return false, "Could not create directory: queries"
	end
	fs.make_dir(queries_dir)
	if not fs.exists(queries_dir) then
		return false, "Could not create directory: " .. queries_dir
	end
	local ok, err = write_queries(queries_dir, build.queries)
	if not ok then
		return false, err
	end
	rockspec.build.copy_directories = rockspec.build.copy_directories or {}
	table.insert(rockspec.build.copy_directories, "queries")
	return true
end

---@param rockspec TreeSitterRockSpec
---@return boolean ok
---@return string? error
local function install_source_queries(rockspec)
	local queries_dir = dir.path("queries", rockspec.build.lang)
	local ok, err = move_query_files("queries", queries_dir)
	if not ok then
		return false, err
	end
	rockspec.build.copy_directories = rockspec.build.copy_directories or {}
	table.insert(rockspec.build.copy_directories, "queries")
	return true
end

---@param rockspec TreeSitterRockSpec
---@return boolean ok
---@return string? error
local function install_queries(rockspec)
	local build = rockspec.build
	local queries_dir = dir.path("queries", build.lang)
	if build.queries then
		return install_inline_queries(rockspec)
	elseif fs.is_dir("queries") and not fs.is_dir(queries_dir) then
		return install_source_queries(rockspec)
	end
	return true
end

--- Build the tree-sitter parser shared library.
---@param build TreeSitterBuildSpec
---@param parser_dir string destination directory for the compiled parser
---@return boolean ok
---@return string? error
local function build_parser_lib(build, parser_dir)
	local parser_lib = build.lang .. "." .. cfg.lib_extension
	if fs.is_tool_available("tree-sitter", "tree-sitter CLI") then
		fs.make_dir(parser_dir)
		local parser_lib_path = dir.path(parser_dir, parser_lib)
		local src_dir = build.location and build.location or fs.current_dir()
		if execute("tree-sitter", "build", "-o", parser_lib_path, src_dir) and fs.exists(parser_lib_path) then
			pcall(function()
				local dsym_file = dir.absolute_name(dir.path(parser_dir, parser_lib .. ".dSYM"))
				if fs.exists(dsym_file) or fs.is_dir(dsym_file) then
					fs.delete(dsym_file)
				end
			end)
			return true
		end
	end
	return false,
		[[
'tree-sitter build' failed.
See the build output for details.
Note: tree-sitter 0.22.2 or later is required to build this parser.
]]
end

--- Copy compiled parser binaries (`.so`/`.dll`) to the install directory
--- for neovim plugin managers that do not symlink the parser directory.
---@param rockspec RockSpec
---@param parser_dir string directory containing compiled parser binaries
local function copy_parser_binaries(rockspec, parser_dir)
	local dest = dir.path(path.install_dir(rockspec.name, rockspec.version), "parser")
	fs.make_dir(dest)
	for _, src in pairs(fs.list_dir(parser_dir)) do
		if src:find("%.so$") ~= nil or src:find("%.dll$") ~= nil then
			fs.copy(dir.path(parser_dir, src), dest)
		end
	end
end

---@param rockspec table
function treesitter_parser.run(rockspec, no_install)
	---@cast rockspec RockSpec
	assert(rockspec.build.type == "treesitter-parser" or rockspec.build.type == "tree-sitter")
	---@cast rockspec TreeSitterRockSpec

	local build = rockspec.build

	if not fs.is_tool_available("tree-sitter", "tree-sitter CLI") then
		return nil,
			"'tree-sitter CLI' is not installed.\n" .. rockspec.name .. " requires the tree-sitter CLI to build.\n"
	end

	local ok, err = generate_grammar(build)
	if not ok then
		return nil, err
	end

	ok, err = install_queries(rockspec)
	if not ok then
		return nil, err
	end

	local lib_dir = path.lib_dir(rockspec.name, rockspec.version)
	local parser_dir = no_install and "luarocks_build" or dir.path(lib_dir, "parser")

	local build_parser = build.parser == nil or build.parser
	if build_parser then
		ok, err = build_parser_lib(build, parser_dir)
	else
		ok = true
	end

	if ok and fs.exists(parser_dir) then
		copy_parser_binaries(rockspec, parser_dir)
	end

	return ok, err
end

return treesitter_parser
