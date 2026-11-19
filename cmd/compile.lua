--	COMPILE.LUA:	Compile, and step through the errors
--
--	Runs a compiler or make in the *compile* buffer, then lists the
--	errors and warnings it reported in the *errors* buffer. Move to an
--	error and press Enter to go to that line, loading the file if it
--	isn't already in a buffer.
--
--	Load it from emacs.lua with
--		me.command("execute-file", "compile.lua")
--	or run it once with M-X execute-file. It adds these commands:
--
--	compile		Ask for a command (make, or gcc for a single file),
--			and run it in the folder of the current file.
--	recompile	Run the last command again, without asking.
--	kill-compile	Stop a compilation that is running.
--	next-error	^X`	Go to the next error or warning.
--	previous-error	^X~	Go to the previous one.
--	goto-error	Enter	(in *errors* or *compile*) Go to the one on
--			this line.
--
--	It understands messages from GCC, Clang and Microsoft C, and
--	follows make's "Entering directory" lines. Windows console
--	version only (it needs me.process).

local M = {}

-- Settings. Change them after loading, for example
--	me.compileoptions.cc = "gcc -Wall -Wextra -g"
me.compileoptions = me.compileoptions or {
	make = "make",			-- for a folder with a makefile
	cc = "gcc -Wall -g",		-- for a single .c file
	cxx = "g++ -Wall -g",		-- for a single C++ file
	save = true,			-- save the current file first
	skipnotes = true,		-- next-error passes over notes
}
local opts = me.compileoptions

local COMPILE = "*compile*"
local LIST = "*errors*"

local windows = package.config:sub(1, 1) == "\\"

-- ------------------------------------------------------------------
--	File names
-- ------------------------------------------------------------------

-- Tidy a path: forward slashes, no "." or "..", MSYS /c/... as c:/...
local function norm(p)
	p = p:gsub("\\", "/")
	if windows then
		p = p:gsub("^/(%a)/", "%1:/"):gsub("^/(%a)$", "%1:/")
	end
	local lead = p:match("^%a:/") or p:match("^/") or ""
	local parts = {}
	for part in p:sub(#lead + 1):gmatch("[^/]+") do
		if part == ".." and #parts > 0 and parts[#parts] ~= ".." then
			parts[#parts] = nil
		elseif part ~= "." then
			parts[#parts + 1] = part
		end
	end
	return lead .. table.concat(parts, "/")
end
M.norm = norm

local function isabs(p)
	return p:match("^%a:[/\\]") ~= nil or p:match("^[/\\]") ~= nil
end

local function join(dir, p)
	if isabs(p) then return norm(p) end
	return norm(dir .. "/" .. p)
end
M.join = join

local function same(a, b)
	if windows then return a:lower() == b:lower() end
	return a == b
end

local function exists(p)
	local f = io.open(p, "rb")
	if f then f:close() return true end
	return false
end

-- The editor's own folder, which relative buffer file names start from
local cwd
local function getcwd()
	if not cwd then
		local h = io.popen(windows and "cd" or "pwd")
		cwd = norm(h and h:read("l") or ".")
		if h then h:close() end
	end
	return cwd
end

local function dirof(file)
	local d = file:match("^(.*)[/\\]")
	if d == nil then return getcwd() end
	if d == "" then d = "/" end
	if file:match("^%a:[/\\][^/\\]*$") then d = file:sub(1, 3) end
	return join(getcwd(), d)
end

-- Show p relative to base when it is inside it
local function relto(p, base)
	local b = base:gsub("/$", "") .. "/"
	if same(p:sub(1, #b), b) then return p:sub(#b + 1) end
	return p
end

-- ------------------------------------------------------------------
--	Reading compiler output
-- ------------------------------------------------------------------

local kinds = { error = "error", warning = "warning", note = "note" }

-- What kind of message the text after "file:line:" is, and the message
local function classify(rest)
	local k, msg = rest:match("^fatal (error)%s*[:%a%d]*:?%s*(.*)$")
	if not k then k, msg = rest:match("^(%a+)%s*[A-Z]*%d*%s*:%s*(.*)$") end
	if not k then k, msg = rest:match("^(%a+)%s+[A-Z]+%d+:%s*(.*)$") end
	if not k then return nil end
	k = kinds[k:lower()]
	if not k then return nil end
	return k, msg
end

-- The file, line, column and the rest of a line of compiler output
local function location(line)
	local f, l, c, rest
	-- GCC and Clang: file:line:col: or file:line:
	f, l, c, rest = line:match("^(%a:[^:]+):(%d+):(%d+):%s*(.*)$")
	if not f then f, l, rest = line:match("^(%a:[^:]+):(%d+):%s*(.*)$") end
	if not f then f, l, c, rest = line:match("^([^:]+):(%d+):(%d+):%s*(.*)$") end
	if not f then f, l, rest = line:match("^([^:]+):(%d+):%s*(.*)$") end
	-- Microsoft C: file(line): or file(line,col):
	if not f then f, l, c, rest = line:match("^%s*(.-)%((%d+),(%d+)%)%s*:%s*(.*)$") end
	if not f then f, l, rest = line:match("^%s*(.-)%((%d+)%)%s*:%s*(.*)$") end
	if not f or f:match("^%s*$") then return nil end
	return f, tonumber(l), tonumber(c), rest
end

-- Every error, warning and note in some compiler output. dir is the
-- folder the command ran in. Each entry has: line (in the output),
-- file (full path), name (as written), row, col, kind, msg.
function M.parse(text, dir)
	local list, dirs = {}, { norm(dir) }
	local n = 0
	for line in text:gmatch("([^\n]*)\n?") do
		n = n + 1
		local d = line:match("Entering directory [`'\"](.-)['\"]")
		if d then
			dirs[#dirs + 1] = join(dirs[#dirs], d)
		elseif line:match("Leaving directory") then
			if #dirs > 1 then dirs[#dirs] = nil end
		else
			local f, row, col, rest = location(line)
			local kind, msg
			if f then kind, msg = classify(rest) end
			if kind then
				list[#list + 1] = { line = n, file = join(dirs[#dirs], f), name = f,
					row = row, col = col or 1, kind = kind, msg = msg }
			end
		end
	end
	return list
end

-- ------------------------------------------------------------------
--	Windows and buffers
-- ------------------------------------------------------------------

-- Make sure there are two windows, and go to the other one
local function otherwindow()
	if me.var.numwind == 1 then me.command("split-current-window") end
	me.command("next-window")
end

-- Run fn in the window showing buffer name (if there is one), then
-- come back. Returns false if no window shows it.
local function inwindow(name, fn)
	local start = me.var.curwind
	for _ = 1, me.var.numwind do
		if me.var.cbufname == name then
			fn()
			while me.var.curwind ~= start do me.command("next-window") end
			return true
		end
		me.command("next-window")
	end
	return false
end

-- Empty a buffer (the current one) and let it be changed
local function clear()
	me.command("delete-mode", "view")
	me.command("beginning-of-file")
	local n = #me.text()
	if n > 0 then me.delete(n) end
end

-- Go to a file: its buffer if it has one, otherwise load it
local function openfile(path)
	for _, name in ipairs(me.buffers(true)) do
		local b = me.buffer(name)
		if b and b.file ~= "" and same(join(getcwd(), b.file), path) then
			return me.command("select-buffer", name)
		end
	end
	if not exists(path) then
		me.message("[Can't find %s]", path)
		return false
	end
	return me.command("find-file", path)
end

-- ------------------------------------------------------------------
--	Compiling
-- ------------------------------------------------------------------

local last = { cmd = nil, dir = nil }	-- for recompile
local lastcmd = {}			-- last command used in each folder
local errs = {}				-- what the last compilation reported
local cur = 0				-- the one we are at
local listline = {}			-- *errors* line -> entry number
local firstline = 1			-- first entry line in *errors*
local gen = 0				-- counts compilations

local function counts(list)
	local e, w = 0, 0
	for _, x in ipairs(list) do
		if x.kind == "error" then e = e + 1 elseif x.kind == "warning" then w = w + 1 end
	end
	return e, w
end

local function plural(n, word)
	return n .. " " .. word .. (n == 1 and "" or "s")
end

-- Fill *errors* (the current buffer) with the list
local function fillist(code)
	clear()
	local e, w = counts(errs)
	me.insert(("%s, %s from: %s\n"):format(plural(e, "error"), plural(w, "warning"), last.cmd))
	me.insert(("In %s. Exit code %s. Press Enter on a line to go there.\n\n")
		:format(last.dir, tostring(code)))
	firstline = 4
	listline = {}
	for i, x in ipairs(errs) do
		local where = relto(x.file, last.dir) .. ":" .. x.row .. ":" .. x.col
		me.insert(("%-8s%s  %s\n"):format(x.kind, where, x.msg))
		listline[firstline + i - 1] = i
	end
	me.command("add-mode", "view")
	me.command("unmark-buffer")
	me.moveto(firstline)
end

-- The compilation has finished
local function finished(mygen, code)
	if mygen ~= gen then return end	-- an older one, stopped
	errs = M.parse(me.text(COMPILE), last.dir)
	cur = 0
	local e, w = counts(errs)
	if #errs > 0 then
		-- show the list where the output was
		if not inwindow(COMPILE, function()
			me.command("select-buffer", LIST)
			fillist(code)
		end) then
			local here = me.var.cbufname
			me.command("select-buffer", LIST)
			fillist(code)
			me.command("select-buffer", here)
		end
	end
	if code == 0 and #errs == 0 then
		me.message("[Compiled with no errors or warnings]")
	elseif #errs == 0 then
		me.message("[Compilation failed, exit code %d; see %s]", code, COMPILE)
	else
		me.message("[%s, %s; ^X` goes to the first]", plural(e, "error"), plural(w, "warning"))
	end
	me.update()
end

-- Run cmd in dir, showing the output in the other window
local function run(cmd, dir)
	local p = me.getprocess(COMPILE)
	if p and p:running() then
		if not me.yesno("A compilation is running. Stop it") then return false end
		p:kill()
		local t = os.clock()
		while p:running() and os.clock() - t < 5 do me.waitoutput(0.1) end
	end
	gen = gen + 1
	local mygen = gen
	last.cmd, last.dir = cmd, dir
	lastcmd[dir:lower()] = cmd
	errs, cur = {}, 0

	otherwindow()
	me.command("select-buffer", COMPILE)
	clear()
	me.insert(("Compiling: %s\nIn %s\n\n"):format(cmd, dir))
	me.command("unmark-buffer")
	local err
	p, err = me.process((windows and "cmd.exe /c " or "") .. cmd, {
		buffer = COMPILE,
		dir = windows and dir:gsub("/", "\\") or dir,
		onexit = function(_, code) finished(mygen, code) end })
	me.command("end-of-file")	-- so the window follows the output
	me.command("previous-window")
	if not p then
		me.message("[%s]", err)
		return false
	end
	me.message("[Compiling...]")
	return true
end
M.run = run

-- The command to suggest for the current buffer
local function suggest(file, dir)
	if lastcmd[dir:lower()] then return lastcmd[dir:lower()] end
	for _, mk in ipairs({ "makefile", "Makefile", "GNUmakefile", "makefile.mk" }) do
		if exists(dir .. "/" .. mk) then return opts.make end
	end
	local name = file:match("[^/\\]+$") or ""
	local stem, ext = name:match("^(.*)%.(%w+)$")
	if ext and ext:lower() == "c" then
		return ("%s -o %s%s %s"):format(opts.cc, stem, windows and ".exe" or "", name)
	elseif ext and ({ cpp = 1, cc = 1, cxx = 1 })[ext:lower()] then
		return ("%s -o %s%s %s"):format(opts.cxx, stem, windows and ".exe" or "", name)
	end
	return opts.make
end

me.defcommand("compile", function()
	local b = me.buffer()
	local dir = b.file ~= "" and dirof(b.file) or getcwd()
	local default = suggest(b.file, dir)
	local cmd = me.prompt("Compile command [" .. default .. "]: ", default)
	if cmd == nil then return false end
	if opts.save and b.changed and b.file ~= "" then me.command("save-file") end
	return run(cmd, dir)
end)

me.defcommand("recompile", function()
	if not last.cmd then
		me.message("[Nothing compiled yet]")
		return false
	end
	if opts.save then
		local b = me.buffer()
		if b.changed and b.file ~= "" then me.command("save-file") end
	end
	return run(last.cmd, last.dir)
end)

me.defcommand("kill-compile", function()
	local p = me.getprocess(COMPILE)
	if not (p and p:running()) then
		me.message("[No compilation is running]")
		return false
	end
	return p:kill()
end)

-- ------------------------------------------------------------------
--	Going to errors
-- ------------------------------------------------------------------

-- Go to entry i. From the list, the file opens in the other window.
local function jump(i)
	local x = errs[i]
	if not x then return false end
	cur = i
	-- keep the list's cursor on this entry
	inwindow(LIST, function() me.moveto(firstline + i - 1) end)
	local name = me.var.cbufname
	if name == LIST or name == COMPILE then otherwindow() end
	if not openfile(x.file) then return false end
	me.moveto(x.row, x.col)
	me.message("[%d/%d] %s: %s", i, #errs, x.kind, x.msg)
	return true
end
M.jump = jump

local function step(dir)
	if #errs == 0 then
		me.message("[No errors]")
		return false
	end
	local i = cur
	repeat
		i = i + dir
	until i < 1 or i > #errs or not (opts.skipnotes and errs[i].kind == "note")
	if i < 1 or i > #errs then
		me.message(dir > 0 and "[No more errors]" or "[No earlier errors]")
		return false
	end
	return jump(i)
end

me.defcommand("next-error", function() return step(1) end)
me.defcommand("previous-error", function() return step(-1) end)

-- The entry on the current line of *errors* or *compile*
local function here()
	local name = me.var.cbufname
	local line = me.point()
	if name == LIST then return listline[line] end
	if name == COMPILE then
		local list = M.parse(me.text(), last.dir or getcwd())
		for i, x in ipairs(list) do
			if x.line == line then
				-- the output may be newer than the list
				if #list ~= #errs then errs, cur = list, 0 end
				return i
			end
		end
	end
	return nil
end

me.defcommand("goto-error", function()
	local i = here()
	if not i then
		me.message("[No error on this line]")
		return false
	end
	return jump(i)
end)

-- for scripts and tests
function M.errors() return errs end
function M.current() return cur end
M.getcwd = getcwd

-- Enter goes to an error in *errors* and *compile*, and does what it
-- did before everywhere else. (Only once, if this file is run again.)
if me.compilekeys then return M end
me.compilekeys = true
local oldret = { me.binding("^M") }
me.bind("^M", function(n, f)
	local name = me.var.cbufname
	if name == LIST or (name == COMPILE and not (me.getprocess() and me.getprocess():running())) then
		return me.command("goto-error")
	end
	if type(oldret[2]) == "function" then return oldret[2](n, f) end
	local old = oldret[1]
	if type(old) ~= "string" or old == "a Lua function" or old:find("^%[") then old = "newline" end
	if f then return me.command(old, n) end
	return me.command(old)
end)
me.bind("^X`", "next-error")
me.bind("^X~", "previous-error")
return M
