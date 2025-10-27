-- AGIAPI/main.lua
-- Core engine for collecting CuberiteAGI API surface
local pluginFolder = cPluginManager:Get():GetCurrentPlugin():GetLocalFolder()
local outDir = pluginFolder .. "/api"

-- --- FILE UTILITIES ---

-- Ensures the output directory exists
local function ensureDir(path)
	cFile:CreateFolder(path)
end

-- Writes content to a file safely
local function writeAll(path, data)
	local f = io.open(path, "wb")
	if not f then 
		LOGERROR(string.format("[AGIAPI] Failed to open file for writing: %s", path))
		return false
	end
	f:write(data)
	f:close()
	return true
end

-- Reads an entire file into a table of lines
local function readLines(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local data = f:read("*a"); f:close()
	local lines = {}
	-- Split data into lines, handling the last line correctly
	for s in (data:gsub("[\r\n]+", "\n").."\n"):gmatch("(.-)\n") do 
		table.insert(lines, s) 
	end
	return lines
end

-- --- SIMPLE JSON ENCODER ---

-- Basic JSON encoder to avoid external dependencies. Handles tables, primitives, and cycles.
local function json_escape(s) return s:gsub('[\\"]','\\%0'):gsub('\n','\\n') end
local function tojson(v, seen)
	local t = type(v)
	if t == "string" then return '"' .. json_escape(v) .. '"'
	elseif t == "number" or t == "boolean" then return tostring(v)
	elseif v == nil then return "null"
	elseif t == "table" then
		seen = seen or {}
		if seen[v] then return '"<cycle>"' end
		seen[v] = true
		
		-- Check if it's an array (sequential integer keys starting from 1)
		local isArr = true; local i = 1
		for k,_ in pairs(v) do if k ~= i then isArr = false break end i = i + 1 end
		
		if isArr then
			local parts = {}
			for i2=1,#v do parts[#parts+1] = tojson(v[i2], seen) end
			return "[" .. table.concat(parts, ",") .. "]"
		else
			local parts = {}
			for k,val in pairs(v) do
				local key = tostring(k)
				parts[#parts+1] = '"'..json_escape(key)..'":'..tojson(val, seen)
			end
			return "{" .. table.concat(parts, ",") .. "}"
		end
	else
		return '"<unsupported type: ' .. t .. '>"'
	end
end

-- --- DOCBLOCK PARSING ---

-- Parses docblocks (---@param / ---@return) preceding a function line
local function parseDocblock(lines, fnLine)
	local doc = { brief = "", params = {}, returns = {} }
	local i = fnLine - 1
	while i >= 1 do
		local l = lines[i]
		-- Stop if line is not a comment line
		if not l:match("^%s*%-%-") then break end
		
		-- Strip leading comment markers (--- or --) and optional leading space
		local text = l:gsub("^%s*%-%-%-?%s?", "")
		
		if text:match("^@param") then
			-- @param name type desc...
			local name, typ, rest = text:match("^@param%s+([%w_%.]+)%s+([%w_%.%[%]|]+)%s*(.*)")
			if name then table.insert(doc.params, 1, { name = name, type = typ, desc = rest:gsub("^%s+", "") }) end
		elseif text:match("^@return") then
			-- @return type desc...
			local typ, rest = text:match("^@return%s+([%w_%.%[%]|]+)%s*(.*)")
			if typ then table.insert(doc.returns, 1, { type = typ, desc = rest:gsub("^%s+", "") }) end
		else
			-- Brief description line (read backwards, so prepend to maintain correct order)
			doc.brief = (text ~= "" and (text .. "\n" .. doc.brief) or doc.brief)
		end
		i = i - 1
	end
	doc.brief = doc.brief:gsub("\n+$",""):gsub("^%s+","") -- Clean up whitespace
	return doc
end

-- Discovers functions defined with explicit signatures in files
local function findFunctionsInFile(path)
	local lines = readLines(path)
	if not lines then return {} end
	local out = {}
	
	-- Patterns to match:
	-- 1. function Namespace.foo(bar, baz)
	-- 2. Namespace.foo = function(bar)
	for ln, s in ipairs(lines) do
		local ns, name, args = s:match("^%s*function%s+([%w_%.]+)%.([%w_]+)%s*%(([^%)]*)%)")
					                           or s:match("^%s*([%w_%.]+)%.([%w_]+)%s*=%s*function%s*%(([^%)]*)%)")
		
		if ns and name then
			local doc = parseDocblock(lines, ln)
			table.insert(out, {
				fqname = ns .. "." .. name,
				ns = ns, name = name,
				args = args:gsub("^%s+",""):gsub("%s+$",""), -- Clean up args string
				doc = doc,
				file = path, line = ln,
				kind = "function"
			})
		end
	end
	return out
end

-- --- RUNTIME REFLECTION ---

-- Recursively walks a namespace table to find functions and constants
local function snapshotTable(rootName, tbl, visited, acc)
	if type(tbl) ~= "table" then return end
	visited = visited or {}
	if visited[tbl] then return end
	visited[tbl] = true
	
	for k, v in pairs(tbl) do
		local ktype = type(k); local vtype = type(v)
		local keyName = tostring(k)
		
		if vtype == "function" then
			-- Find source information for functions found at runtime
			local info = debug.getinfo(v, "S")
			acc[#acc+1] = {
				fqname = rootName .. "." .. keyName,
				ns = rootName, name = keyName,
				file = info and info.short_src or "<C-API>",
				line = info and info.linedefined or -1,
				args = "", -- Arg list must be filled by static analysis (fileFns)
				kind = "function"
			}
		elseif vtype == "table" and not keyName:match("^%d+$") then
			-- Recurse into sub-tables (but ignore array indices to prevent deep cycle checks)
			snapshotTable(rootName .. "." .. keyName, v, visited, acc)
		elseif vtype ~= "userdata" and ktype ~= "number" then
			-- Treat as constant (ignore numerical keys)
			acc[#acc+1] = {
				fqname = rootName .. "." .. keyName,
				ns = rootName, name = keyName,
				kind = "const", value = tostring(v)
			}
		end
	end
end

-- Safely attempts to load a Lua file (module)
local function tryLoad(modulePath)
	local ok, res = pcall(dofile, modulePath)
	if not ok then
		LOGWARNING(string.format("[AGIAPI] Could not load module: %s (%s)", modulePath, tostring(res)))
	end
	return ok
end

-- --- MAIN COLLECTION WORKFLOW ---

local function collect()
	-- Search common paths where CuberiteAGI modules might reside
	local serverPlugins = cPluginManager:GetPluginsPath()
	local agiFolders = {
		serverPlugins .. "/CuberiteAGI",
		serverPlugins .. "/PazuzuTemple", -- if using a specific legacy setup
		pluginFolder .. "/../CuberiteAGI", -- sibling development path
	}
	
	-- List of modules to scan and load. Add your core CuberiteAGI modules here.
	local moduleFiles = {
		"agi_villager_core.lua", "agi_dialogue.lua", "agi_planner.lua",
		"agi_biology.lua", "agi_persistance.lua", "agi_evolution.lua",
		"main.lua", -- catch main file functions if any
	}

	-- 1. Try to load modules into memory (required for runtime snapshot)
	for _, base in ipairs(agiFolders) do
		for _, f in ipairs(moduleFiles) do tryLoad(base .. "/" .. f) end
	end

	-- 2. Static file-level discovery (gets docblocks and argument names)
	local fileFns = {}
	for _, base in ipairs(agiFolders) do
		for _, f in ipairs(moduleFiles) do
			local path = base .. "/" .. f
			for _, fn in ipairs(findFunctionsInFile(path)) do table.insert(fileFns, fn) end
		end
	end

	-- 3. Runtime snapshot from common global roots
	local roots = { "AGI","Biology","Planner","Dialogue","Persist","Evolution" }
	local rtMembers = {}
	for _, r in ipairs(roots) do
		local t = _G[r]
		if type(t) == "table" then snapshotTable(r, t, nil, rtMembers) end
	end
	
	-- 4. Merge static and runtime data
	local byFQName = {}
	
	-- Start with runtime members (ensures we catch all existing objects/functions/constants)
	for _, member in ipairs(rtMembers) do byFQName[member.fqname] = member end
	
	-- Overlay file information (docblocks, args) onto runtime members
	for _, ff in ipairs(fileFns) do
		local m = byFQName[ff.fqname]
		if m then
			-- Merge: prefer file's args/docblock/line number if runtime was vague
			m.args = (ff.args ~= "" and ff.args) or m.args
			m.doc  = ff.doc or m.doc
			m.line = ff.line or m.line
		else
			-- Member only found in file scan (e.g., function definition inside a local block) - still keep it
			byFQName[ff.fqname] = ff
		end
	end

	-- Group final members by namespace
	local groups = {}
	for _, v in pairs(byFQName) do
		local ns = v.ns or "GLOBAL"
		groups[ns] = groups[ns] or { name = ns, members = {} }
		table.insert(groups[ns].members, v)
	end
	
	return groups
end

-- --- RENDERERS ---

-- Renders the human-readable Markdown documentation
local function renderMD(groups)
	local out = { "# CuberiteAGI — API Surface Index\n" }
	for ns, g in pairs(groups) do
		table.insert(out, "\n---\n## Namespace: `"..ns.."`\n")
		table.sort(g.members, function(a,b) return a.fqname < b.fqname end)
		
		for _, m in ipairs(g.members) do
			local sig = ""
			if m.kind == "function" then 
				sig = m.name .. "(" .. (m.args or "") .. ")" 
			elseif m.kind == "const" then 
				sig = m.name .. " = *" .. (m.value or "") .. "*" 
			end
			
			table.insert(out, "\n### `" .. sig .. "`\n")
			
			if m.doc and m.doc.brief ~= "" then table.insert(out, "\n" .. m.doc.brief .. "\n") end
			
			if m.doc and #m.doc.params > 0 then
				table.insert(out, "**Parameters**:\n")
				for _,p in ipairs(m.doc.params) do
					table.insert(out, string.format("- `%s`: *%s* — %s\n", p.name, p.type or "any", p.desc or ""))
				end
			end
			
			if m.doc and #m.doc.returns > 0 then
				table.insert(out, "**Returns**:\n")
				for _,r in ipairs(m.doc.returns) do
					table.insert(out, string.format("- *%s* — %s\n", r.type or "any", r.desc or ""))
				end
			end
			
			if m.file then 
				table.insert(out, string.format("\n<small>Defined in: `%s:%d`</small>\n", m.file:gsub(".*(CuberiteAGI/.*)","%1"), m.line or -1)) 
			end
		end
	end
	return table.concat(out)
end

-- Renders EmmyLua stubs for IDE autocompletion
local function renderEmmy(groups)
	local out = { "---@meta\n---@diagnostic disable\n\n-- CuberiteAGI EmmyLua Stubs - Generated "..os.date()\n" }
	for ns,g in pairs(groups) do
		-- Define the class/namespace
		table.insert(out, ("\n---@class %s\n%s = %s or {}\n"):format(ns, ns, ns))
		
		for _, m in ipairs(g.members) do
			if m.kind == "function" and m.name then
				local params = {}
				local returns = {}
				
				-- Add docblock information
				if m.doc then
					for _,p in ipairs(m.doc.params) do
						table.insert(params, ("---@param %s %s %s"):format(p.name, p.type or "any", p.desc or ""))
					end
					for _,r in ipairs(m.doc.returns) do
						table.insert(returns, ("---@return %s %s"):format(r.type or "any", r.desc or ""))
					end
				end
				
				-- Output full EmmyLua function stub
				for _,l in ipairs(params) do table.insert(out, l.."\n") end
				for _,l in ipairs(returns) do table.insert(out, l.."\n") end
				table.insert(out, ("function %s.%s(%s) end\n\n"):format(ns, m.name, m.args or ""))
			end
		end
	end
	return table.concat(out)
end

-- --- INITIALIZATION & EXECUTION ---

-- Global entry point for the console command
_G.AGIAPI_Run = function()
	local startTime = os.clock()
	
	-- 1. Collect all API surface members
	local groups = collect()
	
	-- 2. Ensure output directory exists
	ensureDir(outDir)

	-- 3. Render and write outputs
	local successCount = 0
	
	-- JSON
	if writeAll(outDir .. "/agi_api.json", tojson(groups)) then successCount = successCount + 1 end

	-- Markdown
	if writeAll(outDir .. "/agi_api.md", renderMD(groups)) then successCount = successCount + 1 end

	-- EmmyLua
	if writeAll(outDir .. "/agi_emmy.lua", renderEmmy(groups)) then successCount = successCount + 1 end
	
	local duration = os.clock() - startTime
	LOG(string.format("[AGIAPI] Generated %d documents for %d namespaces in %.2f seconds.", 
		successCount, 
		(function() local c=0 for _ in pairs(groups) do c=c+1 end return c end)(),
		duration
	))
end

function Initialize(Plugin)
	LOG("[AGIAPI] Core API documentation engine loaded. Ready to generate docs via console command: agiapi")
	return true
end
