-- probe.lua - what a computer on the relay is: its name (a robot's, as the player gave it), and
-- its components. Reads only; changes nothing. For a new robot, before anything is sent to it
-- (Printsize, 2026-10-04): `python 3d-draw/run.py probe <address start>`.

local z = ...
local component = require("component")
local computer = require("computer")

local name = "-"
if component.isAvailable("robot") then
  local ok, n = pcall(component.robot.name)
  if ok and n then name = n end
end
local kinds = {}
for _, kind in component.list() do kinds[#kinds + 1] = kind end
table.sort(kinds)
z.send(("name %s\n"):format(name))
z.send(("energy %d of %d\n"):format(math.floor(computer.energy()),
                                     math.floor(computer.maxEnergy())))
z.send(("components %s\n"):format(table.concat(kinds, " ")))
