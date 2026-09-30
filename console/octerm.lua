--[==[ octerm [host [port]] - stage 1 of octerm: connects to the relay on
the user's PC (port 7777), says hello, and runs the rest of octerm,
its extension, which the relay sends and this caches by hash
(/home/.octerm/octerm_<hash>.lua): the hello names the cached hash, and the
relay sends the code only when its own differs. When the link goes, it
waits and connects again.
    octerm stop     closes a running octerm (typed in its console)
The PC's address is given once, and kept in /home/.octerm/relay for a bare
`octerm` (it is not in the repo: the user's config.ini has it, and
install_octerm.py writes it here too).
This is the only file copied to the computer; everything else comes from
the PC. Frames: console/protocol.h, built by hand (no string.pack in Lua
5.2). The socket's read waits a server tick. ]==]

local component, computer = require("component"), require("computer")
local event, fs = require("event"), require("filesystem")

local args = {...}
if args[1] == "stop" then
  computer.pushSignal("octerm_stop")
  return
end
local VERSION = 2
local CACHE = "/home/.octerm/"
if args[1] then                        -- remembered for a bare `octerm`
  fs.makeDirectory(CACHE)
  local f = assert(io.open(CACHE .. "relay", "w"))
  f:write(args[1] .. " " .. (args[2] or "7777") .. "\n")
  f:close()
else
  local f = io.open(CACHE .. "relay")
  if f then
    args = {f:read("*a"):match("(%S+)%s+(%d+)")}
    f:close()
  end
  if not args[1] then
    io.stderr:write("usage: octerm <PC's address> [port], once\n")
    return
  end
end
local HOST = args[1]
local PORT = tonumber(args[2]) or 7777
local RETRY = 5               -- seconds between attempts to reach the relay

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

local function ext_path(hash)
  return CACHE .. "octerm_" .. hash:gsub("[^%w]", "") .. ".lua"
end

--! Returns the hash of the extension cached here, or "" for none.
local function cached_hash()
  local f = io.open(CACHE .. "octerm_ext")
  if not f then return "" end
  local hash = f:read("*l") or ""
  f:close()
  return fs.exists(ext_path(hash)) and hash or ""
end

--! Returns a socket connected to the relay, or raises why not.
local function connect()
  local s = component.internet.connect(HOST, PORT)
  for _ = 1, 100 do
    if s.finishConnect() then return s end   -- raises if refused
    os.sleep(0.05)
  end
  s.close()
  error("no answer", 0)
end

--! Reads the relay's 'E' frame: returns the extension's hash, its code (nil
--! when it is the cached one), and whatever arrived after it.
local function receive_ext(sock)
  local buf, deadline = "", computer.uptime() + 20
  repeat
    local data = sock.read()
    if data == nil then error("the relay closed the connection", 0) end
    buf = buf .. data
    if #buf > 0 and buf:sub(1, 1) ~= "E" then
      error("the relay sent no extension; is it older than this octerm?", 0)
    end
    local n = #buf >= 2 and buf:byte(2)
    if n and #buf >= 3 + n then
      local hash = buf:sub(3, 2 + n)
      if buf:byte(3 + n) == 0 then return hash, nil, buf:sub(4 + n) end
      if #buf >= 7 + n then
        local len = num(buf, 4 + n, 4)
        if #buf >= 7 + n + len then
          return hash, buf:sub(8 + n, 7 + n + len), buf:sub(8 + n + len)
        end
      end
    end
  until computer.uptime() > deadline
  error("no extension from the relay", 0)
end

--! Connects, gets the extension, and runs it; returns why it ended.
local function session()
  local sock = connect()
  local ok, why = pcall(function()
    local addr, have = computer.address(), cached_hash()
    sock.write("H" .. be(VERSION, 1) .. be(#addr, 1) .. addr
               .. be(#have, 1) .. have)
    local hash, code, rest = receive_ext(sock)
    if code then
      fs.makeDirectory(CACHE)
      local f = assert(io.open(ext_path(hash), "wb"))
      f:write(code)
      f:close()
      f = assert(io.open(CACHE .. "octerm_ext", "wb"))
      f:write(hash)
      f:close()
    else
      local f = assert(io.open(ext_path(hash), "rb"))
      code = f:read("*a")
      f:close()
    end
    local ext = assert(load(code, "=octerm_ext"))
    return ext({sock = sock, inbuf = rest, addr = addr})
  end)
  pcall(sock.close)
  if not ok then error(why, 0) end
  return why
end

--! Waits RETRY seconds; true if octerm stop or Ctrl+C typed here came.
local function stopped()
  return event.pullFiltered(RETRY, function(name, _, char)
    return name == "octerm_stop" or (name == "key_down" and char == 3)
  end) ~= nil
end

if not component.isAvailable("internet") then
  io.stderr:write("octerm: this computer has no Internet Card\n")
  return 1
end
while true do
  local ok, why = pcall(session)
  if ok and why == "stop" then break end
  print(("octerm: %s; trying %s:%d again in %d s (Ctrl+C quits)")
        :format(tostring(why), HOST, PORT, RETRY))
  if stopped() then break end
end
print("octerm: stopped")
