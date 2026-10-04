--[==[ ocscp.lua - the ocscp zone, sent by ocscp.exe: copies one file
between this computer and the PC, then ends. Run by octerm as zone code:
`...` is the zone. Frames: console/protocol.h.

'G' path: the file goes to the PC in pieces ('O' with its size, 'B'
pieces, 'E'), one piece per round of octerm's loop, so the file is never
all in memory. 'P' path, 'B' pieces, 'E': the pieces are written as they
come, and 'K' says how it went, by the file's size on disk. A path not
starting with / is under /home. Binary, byte for byte. ]==]

local zone = ...
local fs = require("filesystem")

local PIECE = 32768
local inbuf = ""
local put, put_path, put_why, written   -- the file being written

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

local function resolve(path)
  if path:sub(1, 1) ~= "/" then path = "/home/" .. path end
  return fs.canonical(path)
end

--! Sends a file in pieces, one per round of octerm's loop.
local function send_file(path)
  path = resolve(path)
  local f, why
  if not fs.exists(path) then why = "no such file"
  elseif fs.isDirectory(path) then why = "it is a directory"
  else f, why = io.open(path, "rb") end
  if not f then
    why = tostring(why)
    zone.send("O" .. be(0, 1) .. be(0, 4) .. be(#why, 2) .. why)
    return
  end
  zone.send("O" .. be(1, 1) .. be(fs.size(path), 4) .. be(0, 2))
  while true do
    local piece = f:read(PIECE)
    if not piece then break end
    zone.send("B" .. be(#piece, 2) .. piece)
    os.sleep(0)                       -- octerm writes it before the next
  end
  f:close()
  zone.send("E")
end

--! Opens the file a 'P' names, making its folder.
local function start_put(path)
  put_path, written = resolve(path), 0
  fs.makeDirectory(fs.path(put_path))
  put, put_why = io.open(put_path, "wb")
end

--! Closes the file being written, and says how it went: by the size it has
--! on disk, since a full disk cuts a file short without writes failing
--! (a 100000-byte file in /tmp, the RAM disk, kept 34464 bytes).
local function end_put()
  local ok, msg = false, tostring(put_why)
  if put then
    put:close()
    local size = fs.size(put_path)
    ok = size == written
    msg = ok and ("wrote " .. written .. " bytes to " .. put_path)
      or (put_path .. " has " .. size .. " of the " .. written
          .. " bytes sent; is its disk full?")
  end
  zone.send("K" .. be(ok and 1 or 0, 1) .. be(#msg, 2) .. msg)
end

--! Takes one whole frame at the start of b; returns the index after it and
--! whether the copy is done, nothing if it has not all arrived, or false.
local function frame(b)
  local t = b:sub(1, 1)
  if t == "G" or t == "P" or t == "B" then
    local text, i = str(b, 2, 2)
    if not text then return end
    if t == "G" then
      send_file(text)
      return i, true
    elseif t == "P" then
      start_put(text)
    elseif put then
      put:write(text)
      written = written + #text
    end
    return i
  elseif t == "E" then
    end_put()
    return 2, true
  end
  return false
end

while true do
  inbuf = inbuf .. zone.wait(math.huge)
  while #inbuf > 0 do
    local used, done = frame(inbuf)
    if used == false then error("ocscp.exe sent a bad frame", 0) end
    if not used then break end
    inbuf = inbuf:sub(used)
    if done then return end           -- what it sent goes out first
  end
end
