-- COMPILETEST.LUA: automated checks for cmd/compile.lua (compiling and
-- stepping through errors). Windows console version, with make and
-- gcc on the PATH.
--
-- Run from the top of the source tree:   emacs @test/compiletest.lua
--
-- The editor runs the checks, writes a report to mecompile-test/results.txt
-- in the temp folder, and exits. The exit status is the number of
-- failed checks (0 means everything passed).

local base = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/")
local dir = base .. "/mecompile-test"
local function mkdir(d)
  os.execute('mkdir "' .. d:gsub("/", "\\") .. '" 2>nul')
end
mkdir(dir)
local out = assert(io.open(dir .. "/results.txt", "w"))
local fails = 0

local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  out:write((cond and "PASS " or "FAIL ") .. name ..
    (extra ~= nil and ("  -- " .. tostring(extra)) or "") .. "\n")
  out:flush()
end

local function eq(name, got, want)
  check(name, got == want, ("got %q want %q"):format(tostring(got), tostring(want)))
end

local function try(name, f)
  local ok, err = pcall(f)
  if not ok then check(name .. " (raised)", false, err) end
end

local function writefile(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

-- Wait for the compilation to finish
local function waitdone(secs)
  local t = os.time()
  repeat
    me.waitoutput(0.2)
    local p = me.getprocess("*compile*")
    if p and not p:running() then return true end
  until os.time() - t > (secs or 60)
  return false
end

local C

try("load", function()
  C = dofile("cmd/compile.lua")
  check("loaded", type(C) == "table")
  for _, name in ipairs({ "compile", "recompile", "kill-compile", "next-error",
                          "previous-error", "goto-error" }) do
    local found = false
    for _, c in ipairs(me.commands()) do if c == name then found = true end end
    check("command " .. name, found)
  end
  eq("^X` bound", me.binding("^X`"), "next-error")
  -- running it again is harmless
  C = dofile("cmd/compile.lua")
  check("load again", type(C) == "table")
end)

try("reading compiler output", function()
  local text = table.concat({
    "gcc -Wall -c a.c",
    "a.c: In function 'main':",
    "a.c:4:9: warning: unused variable 'x' [-Wunused-variable]",
    "     int x;",
    "a.c:5:20: error: 'y' undeclared (first use in this function)",
    "a.c:5:20: note: each undeclared identifier is reported only once",
    "In file included from b.c:1:0:",
    "inc/b.h:2:1: error: unknown type name 'foo'",
    "C:\\src\\c.c:7:3: fatal error: nofile.h: No such file or directory",
    "make[1]: Entering directory '/c/proj/sub'",
    "d.c:9: warning: no column here",
    "make[1]: Leaving directory '/c/proj/sub'",
    "e.c(12): warning C4101: 'z': unreferenced local variable",
    "src\\f.cpp(3,14): error C2065: 'q': undeclared identifier",
    "a.c:(.text+0x1a): undefined reference to `g'",
    "make: *** [makefile:3: all] Error 1",
    "collect2.exe: error: ld returned 1 exit status",
  }, "\n") .. "\n"
  local list = C.parse(text, "C:/proj")
  eq("count", #list, 8)
  local function e(i, kind, file, row, col, msg)
    local x = list[i] or {}
    eq(i .. " kind", x.kind, kind)
    eq(i .. " file", x.file, file)
    eq(i .. " row", x.row, row)
    eq(i .. " col", x.col, col)
    if msg then eq(i .. " msg", x.msg, msg) end
  end
  e(1, "warning", "C:/proj/a.c", 4, 9, "unused variable 'x' [-Wunused-variable]")
  e(2, "error", "C:/proj/a.c", 5, 20, "'y' undeclared (first use in this function)")
  e(3, "note", "C:/proj/a.c", 5, 20)
  e(4, "error", "C:/proj/inc/b.h", 2, 1)
  e(5, "error", "C:/src/c.c", 7, 3, "nofile.h: No such file or directory")
  e(6, "warning", "c:/proj/sub/d.c", 9, 1, "no column here")
  e(7, "warning", "C:/proj/e.c", 12, 1, "'z': unreferenced local variable")
  e(8, "error", "C:/proj/src/f.cpp", 3, 14, "'q': undeclared identifier")
  eq("output line of 1st", list[1].line, 3)
  eq("norm ..", C.norm("C:\\a\\b\\..\\c\\.\\d.c"), "C:/a/c/d.c")
end)

-- a project: a makefile that also builds a subfolder
local proj = dir .. "/proj"
mkdir(proj)
mkdir(proj .. "/util")
writefile(proj .. "/makefile", "all:\n\t$(MAKE) -C util\n\tgcc -Wall -c main.c -o main.o\n")
writefile(proj .. "/util/makefile", "all:\n\tgcc -Wall -c util.c -o util.o\n")
writefile(proj .. "/util/util.c", "int f(void)\n{\n\tint unused;\n\treturn 0;\n}\n")
writefile(proj .. "/main.c", table.concat({
  "#include <stdio.h>",
  "int main(void)",
  "{",
  "    int x;",
  "    printf(\"%d\\n\", y);",
  "    return 0;",
  "}", "" }, "\n"))

try("compile a project", function()
  check("open main.c", me.command("find-file", proj .. "/main.c"))
  check("util.c not loaded yet", me.buffer("util.c") == nil)
  check("compile", me.command("compile", "make"))
  check("finished", waitdone())
  local list = C.errors()
  check("found messages", #list >= 3, #list)
  local text = me.text("*errors*")
  check("summary", text:find("^1 error, 2 warnings from: make\n") ~= nil, text:sub(1, 60))
  check("lists util.c", text:find("warning util/util.c:3:6  unused variable 'unused'", 1, true) ~= nil, text)
  check("lists the error", text:find("error   main.c:5:20  'y' undeclared", 1, true) ~= nil)
  eq("two windows", me.var.numwind, 2)
  eq("still in main.c", me.var.cbufname, "main.c")

  -- step through them
  check("next-error", me.command("next-error"))
  eq("loaded util.c", me.var.cbufname, "util.c")
  eq("at its line", (me.point()), 3)
  eq("and column", select(2, me.point()), 6)
  check("message shown", (me.var.lastmesg or ""):find("[1/", 1, true) ~= nil, me.var.lastmesg)
  -- (GCC reports unused variables at the end of the function)
  check("next-error 2", me.command("next-error"))
  eq("main.c", me.var.cbufname, "main.c")
  eq("line 5", (me.point()), 5)
  eq("column 20", select(2, me.point()), 20)
  check("next-error 3: note skipped", me.command("next-error"))
  eq("line 4", (me.point()), 4)
  eq("column 9", select(2, me.point()), 9)
  check("no more", not me.command("next-error"))
  check("previous-error", me.command("previous-error"))
  eq("back to line 5", (me.point()), 5)
  local n = 0
  for _, b in ipairs(me.buffers()) do if b:find("^main%.c") then n = n + 1 end end
  eq("main.c loaded once", n, 1)

  -- Enter on a line of *errors*
  me.command("select-buffer", "*errors*")
  me.moveto(4)
  check("enter in list", me.runkey("^M"))
  eq("went to util.c", me.var.cbufname, "util.c")
  eq("row", (me.point()), 3)

  -- Enter on a line of *compile*
  me.command("select-buffer", "*compile*")
  local found
  for i = 1, me.buffer().lines do
    me.moveto(i)
    if me.line():find("^main%.c:5:20: error") then found = i break end
  end
  check("error line in output", found ~= nil)
  check("enter in output", me.runkey("^M"))
  eq("went to main.c", me.var.cbufname, "main.c")
  eq("row 5", (me.point()), 5)

  -- Enter on a line with no error
  me.command("select-buffer", "*errors*")
  me.moveto(1)
  check("no error on header", not me.runkey("^M"))

  -- recompile
  me.command("select-buffer", "main.c")
  check("recompile", me.command("recompile"))
  check("finished again", waitdone())
  eq("same messages", #C.errors(), #list)
  eq("list reset", C.current(), 0)
end)

try("Enter elsewhere", function()
  me.command("select-buffer", "plain")
  me.insert("ab")
  me.moveto(1, 2)
  me.runkey("^M")
  eq("newline", me.text(), "a\nb\n")
  me.command("unmark-buffer")
end)

try("a single file", function()
  local d2 = dir .. "/single"
  mkdir(d2)
  os.remove(d2 .. "/makefile")
  writefile(d2 .. "/single.c", "int main(void)\n{\n\treturn 0;\n}\n")
  me.command("find-file", d2 .. "/single.c")
  check("compile with default", me.command("compile", ""))
  check("finished", waitdone())
  check("gcc command", me.text("*compile*"):find("^Compiling: gcc %-Wall %-g %-o single%.exe single%.c\n") ~= nil,
        me.text("*compile*"):sub(1, 80))
  eq("no messages", #C.errors(), 0)
  check("program built", io.open(d2 .. "/single.exe", "rb") ~= nil)
  check("says so", (me.var.lastmesg or ""):find("no errors", 1, true) ~= nil, me.var.lastmesg)
  check("next-error with none", not me.command("next-error"))
end)

out:write(("DONE %d failure(s)\n"):format(fails))
out:close()
me.command("exit-emacs", fails)
