--[==[ octerm_ext.lua - the rest of octerm, stage 2: sent by the relay to
octerm.lua (stage 1) on the computer, cached there by hash, and run with the
connection stage 1 opened: `...` is {sock, inbuf, addr}. Edited here, beside
relay.exe; the relay reads it anew for every computer that says hello.

The monitor: its first two rows say "running: <address>" and "octerm stop to
close", and the rest is a normal console, a shell in an OpenOS window below
them (term.internal.open), for which the monitor is two rows shorter. Its
Ctrl+C is its own. `octerm stop` typed there closes octerm.

Zones: named code a connector sends at its start (cached by hash,
/home/.octerm/<hash>.lua), each in its own thread, talking to that connector
alone. A zone gets zone.name, zone.send(bytes), zone.read() (what arrived,
maybe ""), zone.wait(seconds), zone.on_close(fn), zone.open, and
zone.run(window, path): runs a program as its own process in that OpenOS
window, returning what it returns. A zone ends when its code returns or
fails, when its connector leaves, or on terminate; its cleanups then run.
Ctrl+C and Ctrl+Alt+C inside zones never reach octerm.

Returns why it ended: "stop" (octerm stop), or what happened to the link;
stage 1 connects again for anything but "stop". The socket's read and write
wait a server tick each: it reads every round, writes only what is queued.
Frames: console/protocol.h, built by hand (Lua 5.2 has no string.pack). ]==]

local ctx = ...
local computer, event = require("computer"), require("event")
local fs, process = require("filesystem"), require("process")
local term, thread, tty = require("term"), require("thread"), require("tty")

local CACHE = "/home/.octerm/"
local WAKE = "octerm_zone"    -- pushed with a zone's name when data arrives
local sock, inbuf = ctx.sock, ctx.inbuf
local out, pending = {}, ""
local channels, zones = {}, {}      -- by channel number; by zone name

local function be(n, bytes)            -- n as big-endian bytes
  local s, v = "", math.floor(n) % 256 ^ bytes
  for _ = 1, bytes do s, v = string.char(v % 256) .. s, math.floor(v / 256) end
  return s
end

local function num(s, i, bytes)        -- the big-endian number at s[i]
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

--! Runs a program as its own process in an OpenOS window, and returns what
--! it returns: nothing when a shell exits, 128 when an error killed it. A
--! new process's data falls back to its parent's (lib/process.lua), so the
--! window set on its own table is its, and its children's, alone.
local function run(window, path, ...)
  local co = process.load(path, nil, nil, path)
  rawset(process.info(co).data, "window", window)
  return process.internal.continue(co, ...)
end

--! Queues bytes for a channel's connector, in pieces a 'D' frame carries.
local function to_channel(ch, bytes)
  for i = 1, #bytes, 65535 do
    local part = bytes:sub(i, i + 65534)
    out[#out + 1] = "D" .. be(ch, 1) .. be(#part, 2) .. part
  end
end

local function zone_list()
  local names = {}
  for name in pairs(zones) do names[#names + 1] = be(#name, 1) .. name end
  return "z" .. be(#names, 1) .. table.concat(names)
end

--! Ends a zone: its thread, its cleanups (last first); tells its connector.
local function finish(zone, why)
  if zones[zone.name] ~= zone then return end
  zones[zone.name], zone.open = nil, false
  zone.thread:kill()
  for i = #zone.cleanups, 1, -1 do pcall(zone.cleanups[i]) end
  if channels[zone.ch] then
    channels[zone.ch].zone = nil
    to_channel(zone.ch, "x" .. be(#why, 2) .. why)
  end
end

--! Starts a zone running fn(zone) in its own thread.
local function start(name, ch, fn)
  local zone = {name = name, ch = ch, open = true, inbox = "", cleanups = {},
                run = run}
  function zone.send(b)
    for i = 1, zone.open and #b or 0, 60000 do
      local p = b:sub(i, i + 59999)
      to_channel(ch, "d" .. be(#p, 2) .. p)
    end
  end
  function zone.read() local s = zone.inbox; zone.inbox = ""; return s end
  function zone.wait(s)
    if zone.inbox == "" then event.pull(s, WAKE, name) end
    return zone.read()
  end
  function zone.on_close(fn) zone.cleanups[#zone.cleanups + 1] = fn end
  zone.thread = thread.create(function()
    local ok, err = pcall(fn, zone)
    zone.why = ok and "it returned" or ("error: " .. tostring(err))
  end)
  zones[name] = zone
  return zone
end

--! Opens a zone for a channel, from the code sent or the cached copy.
local function open(ch, name, hash, code)
  local function reply(st, hit, msg) to_channel(ch, "P" .. be(st, 1)
    .. be(hit and 1 or 0, 1) .. be(#msg, 2) .. msg) end
  if zones[name] then return reply(2, false, name .. " is open already") end
  local path, hit = CACHE .. hash:gsub("[^%w]", "") .. ".lua", code == nil
  if hit then
    local f = io.open(path, "rb")
    if not f then return reply(1, false, "not cached") end
    code = f:read("*a")
    f:close()
  else
    fs.makeDirectory(CACHE)
    local f = io.open(path, "wb")
    if f then f:write(code) f:close() end
  end
  local fn, err = load(code, "=" .. name)
  if not fn then return reply(2, hit, "does not load: " .. tostring(err)) end
  channels[ch].zone = start(name, ch, fn)
  reply(0, hit, "")
end

--! Takes one whole frame from a channel's connector, at the start of b;
--! returns the index after it, nothing if it has not all arrived, or false.
local function channel_frame(ch, c, b)
  local t = b:sub(1, 1)
  if t == "d" then
    local data, nxt = str(b, 2, 2)
    if data and c.zone then
      c.zone.inbox = c.zone.inbox .. data
      computer.pushSignal(WAKE, c.zone.name)
    end
    return nxt
  elseif t == "O" then
    local name, i = str(b, 2, 1)
    local hash, j
    if name then hash, j = str(b, i, 1) end
    if not hash or #b < j then return end
    if b:byte(j) == 0 then
      open(ch, name, hash)
      return j + 1
    end
    local code, k = str(b, j + 1, 4)
    if code then open(ch, name, hash, code) end
    return k
  elseif t == "Z" then
    to_channel(ch, zone_list())
    return 2
  elseif t == "T" then
    local name, i = str(b, 2, 1)
    if name and zones[name] then finish(zones[name], "terminated") end
    if name then to_channel(ch, zone_list()) end
    return i
  end
  return false
end

--! Takes the whole frames a channel's connector sent; false on a bad one.
local function take_channel(ch, bytes)
  local c = channels[ch]
  c.buf = c.buf .. bytes
  while #c.buf > 0 do
    local used = channel_frame(ch, c, c.buf)
    if used == false then return false end
    if not used then break end
    c.buf = c.buf:sub(used)
  end
  return true
end

--! Takes the relay's whole frames; false on a bad one.
local function take_relay(data)
  inbuf = inbuf .. data
  while #inbuf > 0 do
    local t, ch = inbuf:sub(1, 1), inbuf:byte(2)
    if t == "G" and ch then
      local c = channels[ch]
      channels[ch] = nil
      if c and c.zone then finish(c.zone, "its connector left") end
      inbuf = inbuf:sub(3)
    elseif t == "D" then
      if #inbuf < 4 or #inbuf < 4 + num(inbuf, 3, 2) then break end
      local n = num(inbuf, 3, 2)
      channels[ch] = channels[ch] or {buf = ""}
      if not take_channel(ch, inbuf:sub(5, 4 + n)) then return false end
      inbuf = inbuf:sub(5 + n)
    elseif t ~= "G" then
      return false
    else
      break
    end
  end
  return true
end

--! Sends what is queued, false once the socket failed; a write may take part.
local function send()
  if #out == 0 and pending == "" then return true end
  local data = pending .. table.concat(out)
  out = {}
  local ok, written = pcall(sock.write, data)
  if not ok or not written then return false end
  pending = data:sub(written + 1)
  return true
end

local function is_stop(name) return name == "octerm_stop" end

--! Moves frames until octerm stop or the relay goes; returns which.
local function loop()
  while true do
    if not send() then return "the relay went away" end
    local ok, data = pcall(sock.read)
    if not ok or data == nil then return "the relay went away" end
    if not take_relay(data) then return "the relay sent a bad frame" end
    for _, zone in pairs(zones) do
      if zone.thread:status() == "dead" then finish(zone, zone.why) end
    end
    if event.pullFiltered(0, is_stop) then return "stop" end
  end
end

-- Ctrl+Alt+C raises in whichever process runs: ignored in octerm and zones'
-- threads, which share its data; programs they start inherit this function
-- and still get it, the local console's shell included.
local me = process.info().data
me.signal = function(msg, level)
  if process.info().data ~= me then error(msg, level) end
end

-- The monitor: two rows of header, and a console in the rest.
term.clear()
print("running: " .. ctx.addr)
print("octerm stop to close")
local w, h = tty.gpu().getViewport()
local console = thread.create(function()
  local window = term.internal.open(0, 2, w, h - 2)
  while true do                       -- a shell that exits or is killed
    run(window, "/bin/sh.lua")        -- comes back, as init's does
    os.sleep(0)
  end
end)

local fine, why = pcall(loop)
console:kill()
for _, zone in pairs(zones) do finish(zone, "octerm closed") end
send()
pcall(sock.close)
term.clear()
return fine and why or ("error: " .. tostring(why))
