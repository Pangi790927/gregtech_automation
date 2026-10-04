--[==[ claude-oc.lua - the claude-oc zone, sent by claude-oc.exe: Claude's
hands on this computer, and the `claude` program's way to Claude. Run by
octerm as zone code: `...` is the zone. Frames: console/protocol.h.

claude-oc.exe first sends the `claude` program ('I'), written here to
/home/bin/claude.lua, where OpenOS's PATH finds it, then this computer's
session as it keeps it ('S'): one computer is one Claude session, kept on
the PC until `claude stop`. The program and this zone share a table,
package.loaded["claude-oc"] (both run in this Lua state; signals only wake
the program): start(dir) joins the session, making it, working in `dir`,
if there is none, and tells an earlier `claude` it was taken over;
stop() ends the session; ask(me, text) sends a prompt; take(me) returns
what came back: {"note", text}, {"answer", id, text}, {"no_answer", id,
why}, {"pc_prompt", text} (typed in claude-oc.exe's window; its answer has
id 0), {"mail", from, text}, {"stopped"}, {"taken"}, {"gone"} once this
zone ended. Mail, kept on the PC: send(to, text) sends a letter to the
computer whose address starts `to`, mail() asks for this one's mailbox;
each returns an id whose answer reply(id) gives, {ok, text}, once it came.

Tools ('T') run one thread each, so the zone keeps taking frames: oc_run
runs a command line with OpenOS's sh, oc_lua a chunk of Lua, each as a
process of its own whose stdin is empty and whose stdout and stderr are
captured (a process's io is its data.io, which print, io.write and
term.write all reach: boot/03_io.lua, lib/term.lua); oc_read and oc_write
work on files. The session keeps its own environment variables (its
working directory, which the PC keeps too: 'D' when a tool moves it) and
its own Lua globals for oc_lua, which a reboot loses.
A tool past its time limit is killed, and says what it printed so far.
Programs that draw on the GPU directly draw on the monitor. ]==]

local zone = ...
local computer, event, fs = require("computer"), require("event"),
  require("filesystem")
local buffer, process, sh = require("buffer"), require("process"),
  require("sh")
local serialization, thread = require("serialization"), require("thread")

local PROGRAM = "/home/bin/claude.lua"
local WAKE = "claude_oc"              -- wakes the program: something came
local RUN_OUT, READ_OUT = 16000, 60000
local inbuf = ""
local vars, lua_env                   -- the session's own

local function be(n, bytes)           -- n as big-endian bytes
  local s, v = "", math.floor(n) % 256 ^ bytes
  for _ = 1, bytes do s, v = string.char(v % 256) .. s, math.floor(v / 256) end
  return s
end

local function num(s, i, bytes)       -- the big-endian number at s[i]
  local v = 0
  for k = i, i + bytes - 1 do v = v * 256 + s:byte(k) end
  return v
end

--! Reads a string prefixed by its length (`bytes` bytes) from s at i;
--! returns it and the index after it, or nothing if it has not all arrived.
local function str(s, i, bytes)
  if #s < i + bytes - 1 then return end
  local n = num(s, i, bytes)
  if #s < i + bytes + n - 1 then return end
  return s:sub(i + bytes, i + bytes + n - 1), i + bytes + n
end

-- THE PROGRAM'S SIDE ------------------------------------------------------

-- known: the PC has said whether there is a session; session: there is.
local shared = {alive = true, inbox = {}, next_id = 0, known = false,
                session = false, replies = {}, next_req = 0}

--! Hands the program something that came back, and wakes it.
local function deliver(...)
  if shared.owner then shared.inbox[#shared.inbox + 1] = table.pack(...) end
  computer.pushSignal(WAKE)
end

--! The session's state here: variables from octerm's, working in `dir`,
--! and Lua globals of its own.
local function set_session(dir)
  vars = {}
  for k, v in pairs(process.info().data.vars or {}) do vars[k] = v end
  vars.PWD = dir
  lua_env = setmetatable({}, {__index = function(_, k)   -- libraries as
    local v = _G[k]                                       -- globals, as the
    if v == nil then                                      -- `lua` prompt has
      local ok, lib = pcall(require, k)                   -- them (lib/core/
      if ok then v = lib end                              -- lua_shell.lua)
    end
    return v
  end})
end

--! Starts a `claude`: it takes the screen over from an earlier one, and
--! the first makes the session, working in `dir`. Returns its handle,
--! whether it made the session, and the session's working directory; or
--! nil and why, while the PC has not yet said whether there is one.
function shared.start(dir)
  if not shared.known then
    return nil, "claude-oc.exe is still attaching; try again in a moment"
  end
  computer.pushSignal(WAKE)           -- an earlier one finds it was taken
  local me = {}
  shared.owner, shared.inbox = me, {}
  local made = not shared.session
  if made then
    shared.session = true
    set_session(dir)
    zone.send("B" .. be(#dir, 2) .. dir)
  end
  return me, made, vars.PWD
end

--! Ends the session (`claude stop`); the next `claude` makes a new one.
--! A `claude` still open is told. Returns false when there was none.
function shared.stop()
  if not shared.session then return false end
  shared.session, vars = false, nil
  deliver("stopped")
  zone.send("R")
  return true
end

function shared.ask(me, text)
  if me ~= shared.owner then return nil, "another claude took over" end
  shared.next_id = shared.next_id % 65535 + 1
  zone.send("Q" .. be(shared.next_id, 2) .. be(#text, 4) .. text)
  return shared.next_id
end

function shared.take(me)
  if not shared.alive then return {table.pack("gone")} end
  if me ~= shared.owner then return {table.pack("taken")} end
  local got = shared.inbox
  shared.inbox = {}
  return got
end

function shared.quit(me)
  if me == shared.owner then shared.owner = nil end
end

local function request(frame)
  shared.next_req = shared.next_req % 65535 + 1
  zone.send(frame(be(shared.next_req, 2)))
  return shared.next_req
end

function shared.send(to, text)
  return request(function(id)
    return "M" .. id .. be(#to, 1) .. to .. be(#text, 4) .. text
  end)
end

function shared.mail()
  return request(function(id) return "G" .. id end)
end

function shared.reply(id)
  local r = shared.replies[id]
  shared.replies[id] = nil
  return r
end

package.loaded["claude-oc"] = shared
zone.on_close(function()
  shared.alive = false
  if package.loaded["claude-oc"] == shared then
    package.loaded["claude-oc"] = nil
  end
  computer.pushSignal(WAKE)
end)

-- THE TOOLS ---------------------------------------------------------------

--! Returns a path as the session's working directory makes it.
local function resolve(path)
  if path:sub(1, 1) == "/" then return fs.canonical(path) end
  return fs.canonical(fs.concat(vars.PWD or "/", path))
end

--! Returns what `value` reads as, tables included.
local function show(value)
  if type(value) == "string" then return value end
  local ok, s = pcall(serialization.serialize, value, true)
  return ok and s or tostring(value)
end

--! Runs fn as a process of its own, stdin empty, stdout and stderr into
--! `parts`, with the session's variables; returns what fn returns.
local function run_captured(fn, parts)
  local sink = {write = function(_, s) parts[#parts + 1] = s return true end,
                close = function() return true end}
  local empty = {read = function() return nil end,
                 close = function() return true end}
  local out = buffer.new("w", sink)
  out:setvbuf("no")
  local co = process.load(fn, nil, nil, "claude-oc")
  local data = process.info(co).data
  data.io[0], data.io[1], data.io[2] = buffer.new("r", empty), out, out
  rawset(data, "vars", vars)
  return process.internal.continue(co)
end

--! Runs fn(parts) in a thread for at most `limit` seconds; returns ok and
--! the text to answer with.
local function limited(limit, cap, fn)
  local parts, ok, text = {}, false, nil
  local t = thread.create(function() ok, text = fn(parts) end)
  t:join(limit)
  local printed = table.concat(parts)
  if t:status() ~= "dead" then
    t:kill()
    ok, text = false, "stopped after " .. limit .. " s"
  end
  text = printed .. (text and ((printed ~= "" and "\n" or "") .. text) or "")
  if #text > cap then
    text = text:sub(1, cap) .. "\n[cut: " .. #text .. " bytes in all]"
  end
  return ok, text
end

local tools = {}

function tools.oc_run(a)
  return limited(tonumber(a.timeout) or 30, RUN_OUT, function(parts)
    local ok, why = run_captured(function()
      return sh.execute(nil, a.command or "")
    end, parts)
    if ok == true then return true, nil end     -- 128: an error killed it
    return false, "failed" .. (why and (": " .. tostring(why)) or "")
  end)
end

function tools.oc_lua(a)
  return limited(tonumber(a.timeout) or 30, RUN_OUT, function(parts)
    local chunk, err = load(a.code or "", "=oc_lua", "t", lua_env)
    if not chunk then return false, "does not load: " .. tostring(err) end
    local r = run_captured(function() return table.pack(pcall(chunk)) end,
                           parts)
    if type(r) ~= "table" then return false, "the process failed" end
    if not r[1] then return false, "error: " .. tostring(r[2]) end
    local shown = {}
    for i = 2, r.n do shown[#shown + 1] = show(r[i]) end
    return true, #shown > 0 and ("returned: " .. table.concat(shown, ", "))
      or nil
  end)
end

function tools.oc_read(a)
  local path = resolve(a.path or "")
  local f, err = io.open(path, "rb")
  if not f then return false, path .. ": " .. tostring(err) end
  local data = f:read(READ_OUT + 1) or ""
  f:close()
  if #data > READ_OUT then
    data = data:sub(1, READ_OUT) .. "\n[cut at " .. READ_OUT .. " bytes]"
  end
  return true, data
end

function tools.oc_write(a)
  local path = resolve(a.path or "")
  fs.makeDirectory(fs.path(path))
  local f, err = io.open(path, "wb")
  if not f then return false, path .. ": " .. tostring(err) end
  f:write(a.content or "")
  f:close()
  return true, "wrote " .. #(a.content or "") .. " bytes to " .. path
end

--! Runs a tool in a thread of its own, and sends its result; before it,
--! the working directory, when the tool moved it (`cd`).
local function start_tool(id, name, args)
  thread.create(function()
    local tool = tools[name]
    local ok, text = false, "there is no tool " .. name
    if not vars then
      text = "this computer has no session; the first `claude` makes one"
    elseif tool then
      local before = vars.PWD
      local fine, a, b = pcall(tool, args)
      if fine then ok, text = a, b else text = "error: " .. tostring(a) end
      local now = vars and vars.PWD
      if now and now ~= before then zone.send("D" .. be(#now, 2) .. now) end
    end
    text = text or ""
    zone.send("U" .. be(id, 2) .. be(ok and 1 or 0, 1) .. be(#text, 4) .. text)
  end)
end

-- FRAMES ------------------------------------------------------------------

--! Takes a 'T' frame's body at i: id, tool, arguments; returns the index
--! after it, or nothing if it has not all arrived.
local function take_tool(b, i)
  if #b < i + 1 then return end
  local id = num(b, i, 2)
  local name, j = str(b, i + 2, 1)
  if not name or #b < j then return end
  local args, count = {}, b:byte(j)
  j = j + 1
  for _ = 1, count do
    local key, value
    key, j = str(b, j, 1)
    if not key then return end
    value, j = str(b, j, 4)
    if not value then return end
    args[key] = value
  end
  start_tool(id, name, args)
  return j
end

--! Takes one whole frame at the start of b; returns the index after it,
--! nothing if it has not all arrived, or false on a bad one.
local function frame(b)
  local t = b:sub(1, 1)
  if t == "I" then
    local code, i = str(b, 2, 4)
    if not code then return end
    fs.makeDirectory(fs.path(PROGRAM))
    local f = io.open(PROGRAM, "wb")
    if f then f:write(code) f:close() end
    return i
  elseif t == "S" then
    if #b < 2 then return end
    local dir, i = str(b, 3, 2)
    if not dir then return end
    shared.known, shared.session = true, b:byte(2) == 1
    if shared.session then set_session(dir) else vars = nil end
    return i
  elseif t == "A" or t == "X" then
    if #b < 3 then return end
    local text, i = str(b, 4, t == "A" and 4 or 2)
    if not text then return end
    deliver(t == "A" and "answer" or "no_answer", num(b, 2, 2), text)
    return i
  elseif t == "N" or t == "P" then
    local text, i = str(b, 2, t == "N" and 2 or 4)
    if text then deliver(t == "N" and "note" or "pc_prompt", text) end
    return i
  elseif t == "L" then
    local from, i = str(b, 2, 1)
    local text, j
    if from then text, j = str(b, i, 4) end
    if not text then return end
    deliver("mail", from, text)
    return j
  elseif t == "Y" then
    if #b < 4 then return end
    local text, i = str(b, 5, 4)
    if not text then return end
    shared.replies[num(b, 2, 2)] = {b:byte(4) == 1, text}
    computer.pushSignal(WAKE)
    return i
  elseif t == "T" then
    return take_tool(b, 2)
  end
  return false
end

while true do
  inbuf = inbuf .. zone.wait(math.huge)
  while #inbuf > 0 do
    local used = frame(inbuf)
    if used == false then error("claude-oc.exe sent a bad frame", 0) end
    if not used then break end
    inbuf = inbuf:sub(used)
  end
end
