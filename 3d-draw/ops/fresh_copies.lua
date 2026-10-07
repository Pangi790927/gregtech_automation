-- Every idle builder's copy made anew on the simbot now loaded (a copy's body keeps the hw it
-- was made with: the leaves fix reached only new bodies, ASIMO's copy diverged at op 83). The
-- same as copy.lua's copy_of, standing where the robot is. A running one is left as it is.
local copy, simbot, machine = require("copy"), require("simbot"), require("machine")
local robots, crew = require("robots"), require("crew")
local function deep(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deep(v) end
    return o
end
local out = {}
for _, n in ipairs(NAMES or crew.BUILDERS) do
    local r = robots.by[n]
    local sf = r and r.sf
    if not sf or sf.state == "run" or sf.state == "wait" or robots.in_flight(r) or crew.jobs[n] then
        out[#out + 1] = n .. ": busy, left"
    else
        local w = copy.world()
        if r.copy then w:set(r.copy.b.x, r.copy.b.y, r.copy.b.z, nil) end
        w:set(sf.pos[1], sf.pos[2], sf.pos[3], nil)
        local b = simbot.robot(w, {x = sf.pos[1], y = sf.pos[2], z = sf.pos[3], facing = sf.facing,
                                   energy = sf.energy, max = 40500, slots = deep(r.slots or {}),
                                   name = r.name})
        r.copy = {b = b, m = machine.new(b.hw, {x = b.x, y = b.y, z = b.z, facing = b.facing})}
        r.diverged = nil
        out[#out + 1] = n .. ": copy made anew at " .. table.concat(sf.pos, ",")
    end
end
return table.concat(out, "\n")
