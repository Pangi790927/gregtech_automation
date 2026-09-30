--[==[ term.lua - the terminal zone, sent by term.exe: a shell on a virtual
screen inside this computer, shown in term.exe's window and typed into from
there. Run by octerm as zone code: `...` is the zone.

The shell runs as its own process in its own OpenOS window (zone.run), with
its own keyboard address, so keys from the PC reach it alone and keys typed
on the computer reach the computer's own console alone. It draws into a GPU
buffer (video RAM) as large as the GPU can draw: maxResolution would be
less, being capped by the monitor too.

The GPU is shared with the computer's console, so its functions are wrapped
on the tty's proxy (as OpenOS's tty.bind wraps setResolution; component.proxy
caches it) and each call is routed by who makes it: the zone's shell and its
programs, whose window is this zone's, draw into the buffer and are mirrored
to term.exe; everyone else draws on the monitor as before. Each side keeps
its own active buffer and colours, and the GPU is switched to a side's only
when that side draws or asks it something, so between calls it may be on
either: component.invoke, which passes the proxy by, sees whichever it is,
and one that switches buffers itself leaves this out of step until the zone
ends. getViewport and getResolution answer the zone with its virtual size;
setResolution and setViewport resize it, within the buffer.

term.exe sends its window's size ('W') at the start and on every change, and
the virtual screen follows it: a screen larger than the window was drawn
past its bottom, which scrolled the window. The shell starts after the first
size, so OpenOS lays out its banner to fit.

Keys arrive as 'K' frames and are pushed as key_down/key_up from the zone's
keyboard address, with the player "octerm". Before them, any Ctrl, Shift or
Alt the computer thinks held but the PC did not press is released: an
Alt+Tab out of Minecraft leaves Alt down, and the PC's next Ctrl+C would
read as Ctrl+Alt+C. A shell that Ctrl+Alt+C kills is started again; exit
ends the zone. One terminal zone at a time. ]==]

local zone = ...
local computer, keyboard = require("computer"), require("keyboard")
local process, term = require("process"), require("term")
local thread, tty = require("thread"), require("tty")

if package.loaded["octerm.terminal"] then
  error("a terminal zone is open already", 0)
end
package.loaded["octerm.terminal"] = true
zone.on_close(function() package.loaded["octerm.terminal"] = nil end)

local MODS = {0x1D, 0x9D, 0x2A, 0x36, 0x38, 0xB8}  -- ctrl, shift, alt
local KEYBOARD = "octerm-" .. zone.name           -- the zone's own keyboard
local gpu, orig, vbuf, window
local vw, vh, bw, bh                     -- the virtual screen; its buffer
local out, inbuf, pc_held = {}, "", {}

--! Big-endian bytes of n; signed values as their two's complement.
local function be(n, bytes)
  local s, v = "", math.floor(n) % 256 ^ bytes
  for _ = 1, bytes do s, v = string.char(v % 256) .. s, math.floor(v / 256) end
  return s
end
local function u8(n) return be(n, 1) end
local function u16(n) return be(n, 2) end
local function u24(n) return be(n, 3) end

local function flush()
  if #out > 0 then zone.send(table.concat(out)) out = {} end
end

--[[ The two sides of the GPU: what each wants, and what the GPU has now. ]]

local monitor, virtual, now = {}, {}, {}

--! Returns the side whose call this is: the zone's shell and everything it
--! starts have this zone's window; anyone else is the monitor's.
local function side()
  local info = process.info()
  return info and info.data.window == window and virtual or monitor
end

--! Switches the GPU to a side's buffer and colours, where they differ.
local function enter(s)
  if now.buf ~= s.buf then orig.setActiveBuffer(s.buf) now.buf = s.buf end
  if now.fg ~= s.fg or now.fp ~= s.fp then
    orig.setForeground(s.fg, s.fp) now.fg, now.fp = s.fg, s.fp
  end
  if now.bg ~= s.bg or now.bp ~= s.bp then
    orig.setBackground(s.bg, s.bp) now.bg, now.bp = s.bg, s.bp
  end
end

local function rgb(v, p) return p and orig.getPaletteColor(v) or v end

--! Queues a frame for term.exe when the virtual side drew into its buffer.
local function mirror(s, frame)
  if s == virtual and s.buf == vbuf then out[#out + 1] = frame end
end

--! Tells term.exe the size, and the zone's window takes it.
local function resized()
  window.width, window.height = vw, vh
  out[#out + 1] = "R" .. u16(vw) .. u16(vh)
end

--! Resizes the virtual screen within its buffer, as setResolution would.
local function set_size(w, h)
  if w < 1 or h < 1 or w > bw or h > bh then
    return nil, "unsupported resolution"
  end
  vw, vh = w, h
  resized()
  return true
end

local WRAPPED = {"set", "fill", "copy", "get", "setForeground",
  "setBackground", "getForeground", "getBackground", "setActiveBuffer",
  "getActiveBuffer", "setResolution", "setViewport", "getResolution",
  "getViewport", "maxResolution"}

--! Returns a replacement for a drawing function: it runs on the caller's
--! side, and frame(...) is the mirror of it, if any.
local function drawing(name, frame)
  return function(...)
    local s = side()
    enter(s)
    local results = table.pack(orig[name](...))
    if frame then mirror(s, frame(s, ...)) end
    return table.unpack(results, 1, results.n)
  end
end

--! Returns a replacement that answers the virtual side with fn(...), and the
--! monitor's with the GPU's own answer, after switching to the monitor's
--! buffer: asked while the zone's buffer was active, the GPU answered about
--! the buffer (getViewport said 50x160 of a 160x50 monitor, in the game).
local function virtually(name, fn)
  return function(...)
    if side() == virtual then return fn(...) end
    enter(monitor)
    return orig[name](...)
  end
end

--! Returns a colour setter for field f ("fg"/"bg") of the caller's side:
--! recorded, applied when that side next draws. Returns the old colour, and
--! its palette index if it was one, as the GPU does.
local function colour_setter(f)
  return function(value, palette)
    local s = side()
    local old, oldp = s[f], s[f .. "p"]
    s[f], s[f .. "p"] = value, palette and true or false
    return rgb(old, oldp), oldp and old or nil
  end
end

local function colour_getter(f)
  return function() local s = side() return s[f], s[f .. "p"] end
end

local function wrap()
  gpu, orig = tty.gpu(), {}
  for _, name in ipairs(WRAPPED) do orig[name] = gpu[name] end
  monitor.buf = orig.getActiveBuffer()
  monitor.fg, monitor.fp = orig.getForeground()
  monitor.bg, monitor.bp = orig.getBackground()
  now.buf, now.fg, now.fp = monitor.buf, monitor.fg, monitor.fp
  now.bg, now.bp = monitor.bg, monitor.bp
  virtual.buf, virtual.fg, virtual.fp = vbuf, 0xFFFFFF, false
  virtual.bg, virtual.bp = 0x000000, false
  gpu.set = drawing("set", function(s, x, y, text, vertical)
    text = tostring(text)
    return "S" .. u16(x) .. u16(y) .. u24(rgb(s.fg, s.fp))
        .. u24(rgb(s.bg, s.bp)) .. u8(vertical and 1 or 0) .. u16(#text) .. text
  end)
  gpu.fill = drawing("fill", function(s, x, y, w, h, c)
    c = tostring(c)
    return "F" .. u16(x) .. u16(y) .. u16(w) .. u16(h) .. u24(rgb(s.fg, s.fp))
        .. u24(rgb(s.bg, s.bp)) .. u8(#c) .. c
  end)
  gpu.copy = drawing("copy", function(_, x, y, w, h, tx, ty)
    return "C" .. u16(x) .. u16(y) .. u16(w) .. u16(h) .. u16(tx) .. u16(ty)
  end)
  gpu.get = drawing("get")
  gpu.setForeground = colour_setter("fg")
  gpu.setBackground = colour_setter("bg")
  gpu.getForeground = colour_getter("fg")
  gpu.getBackground = colour_getter("bg")
  gpu.setActiveBuffer = function(index) side().buf = index return true end
  gpu.getActiveBuffer = function() return side().buf end
  local function size() return vw, vh end
  gpu.getResolution = virtually("getResolution", size)
  gpu.getViewport = virtually("getViewport", size)
  gpu.maxResolution = virtually("maxResolution", function() return bw, bh end)
  gpu.setResolution = virtually("setResolution", set_size)
  gpu.setViewport = virtually("setViewport", set_size)
end

--! Gives the GPU back as the monitor's side wants it, and its functions.
local function unwrap()
  enter(monitor)
  for name, fn in pairs(orig) do gpu[name] = fn end
end

--[[ Keys and window sizes from term.exe. ]]

--! Lets go of Ctrl, Shift and Alt the computer thinks held but the PC did
--! not press.
local function release_stale()
  for _, code in ipairs(MODS) do
    if keyboard.pressedCodes[code] and not pc_held[code] then
      computer.pushSignal("key_up", KEYBOARD, 0, code, "octerm")
    end
  end
end

--! Takes term.exe's frames: 'K' keys, pushed as signals from the zone's
--! keyboard, and 'W' window sizes. Returns whether a 'W' came.
local function take_input(data)
  local sized = false
  release_stale()
  inbuf = inbuf .. data
  while #inbuf > 0 do
    local t = inbuf:sub(1, 1)
    if t == "W" and #inbuf >= 5 then
      local b = {inbuf:byte(2, 5)}
      local w, h = b[1] * 256 + b[2], b[3] * 256 + b[4]
      if w >= 1 and h >= 1 then set_size(math.min(w, bw), math.min(h, bh)) end
      inbuf, sized = inbuf:sub(6), true
    elseif t == "K" and #inbuf >= 8 then
      local b = {inbuf:byte(2, 8)}
      inbuf = inbuf:sub(9)
      local char = ((b[2] * 256 + b[3]) * 256 + b[4]) * 256 + b[5]
      local code = b[6] * 256 + b[7]
      pc_held[code] = b[1] == 1 or nil
      computer.pushSignal(b[1] == 1 and "key_down" or "key_up", KEYBOARD,
                          char, code, "octerm")
    elseif t ~= "W" and t ~= "K" then
      error("term.exe sent a bad frame", 0)
    else
      break
    end
  end
  return sized
end

--[[ The zone. ]]

-- With no size, a buffer is as large as the GPU itself can draw.
local g = tty.gpu()
vbuf = g.allocateBuffer and g.allocateBuffer()
if not vbuf then error("this GPU has no video memory for a screen", 0) end
zone.on_close(function() g.freeBuffer(vbuf) end)
bw, bh = g.getBufferSize(vbuf)
vw, vh = bw, bh
window = term.internal.open(0, 0, vw, vh)
window.keyboard = KEYBOARD
wrap()
zone.on_close(unwrap)

-- The window's size comes first; the shell lays out its banner by it.
local deadline = computer.uptime() + 3
repeat until take_input(zone.wait(0.5)) or computer.uptime() > deadline
resized()
flush()

local sh = thread.create(function()
  while zone.run(window, "/bin/sh.lua") ~= nil do os.sleep(0) end
end)                                  -- killed (128) comes back; exit ends
zone.on_close(function() sh:kill() end)   -- registered last, so run first
while sh:status() ~= "dead" do
  flush()
  local data = zone.wait(0.05)
  if data ~= "" then take_input(data) end
end
flush()
