-- read_me.lua - runs on the computer with the Adapter at the mini ME (not on a robot): lists what
-- the mini ME holds, one line per kind of item, for 3d-draw's house design.
--
-- getItemsInNetwork walks the whole network's item list on the server's thread; on a big network
-- that crashed the server (OpenComputers 1.9.14 still does it the same way). It is safe here only
-- because the mini ME is a network of its own (the user confirmed it, 2026-10-04): nothing in this
-- program can make a big network safe, since the walk happens inside the call. MAX only stops a
-- surprising answer from being sent line by line.

local z = ...
local component = require("component")
local MAX = 2000
local function say(s) z.send(tostring(s)); os.sleep(0) end

local me
for addr, kind in component.list() do
  say("component " .. kind .. " " .. addr:sub(1, 8))
  if not me and (kind == "me_interface" or kind == "me_controller" or kind:find("^me_")) then
    me = component.proxy(addr)
  end
end
if not me then say("no ME component: is the Adapter touching a block of the mini ME?") return end
if not me.getItemsInNetwork then say("the ME component has no getItemsInNetwork") return end

local items = me.getItemsInNetwork()
if not items then say("getItemsInNetwork gave nothing") return end
if #items > MAX then
  say(("%d kinds of item: not a mini ME? stopped"):format(#items))
  return
end
say(("items: %d kinds"):format(#items))
for _, it in ipairs(items) do
  say(("item %s %d %d %s"):format(it.name, it.damage or 0, it.size or 0, it.label or "?"))
end
