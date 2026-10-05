--[[ The robots' copies (scripts/copy.lua): a dry run ends done or names the stop, and a copy
-- followed through a robot's status_fast lines agrees with it, or reports where the two part.
-- @date 2026-10-05 ]]

local copy = require("copy")
local machine = require("machine")
local simbot = require("simbot")
local view = require("view")

local function run_test()
    -- a world of its own: one stone east of the robot's start
    view.terrain = {}
    view.anchor = {0, 0, 0}
    view.terrain["3,0,0"] = {3, 0, 0, "minecraft:stone", 0, "seen", false}
    -- a floor at y -2, so a block put down at y -1 has something under it (no angel upgrade)
    for x = -2, 6 do
        for z = -3, 3 do
            view.terrain[x .. ",-2," .. z] = {x, -2, z, "minecraft:stone", 0, "seen", false}
        end
    end
    local r = {name = "t", sf = {id = "-", state = "idle", op = 1, pos = {0, 0, 0}, facing = "e",
               energy = 40000}}
    copy.inventory(r, "1:minecraft:cobblestone:0:5;3:minecraft:ladder:0:14")
    if not r.slots[3] or r.slots[3].name ~= "minecraft:ladder" or r.slots[3].count ~= 14 then
        return "the inventory line"
    end
    local d = copy.dry(r, "$0 >3")
    if d.state ~= "stop" or d.why ~= "blocked minecraft:stone" then
        return "the dry run into the stone: " .. d.state .. " " .. tostring(d.why)
    end
    if copy.world():get(3, 0, 0) == nil then return "the dry run changed the copies' world" end
    d = copy.dry(r, "$0 >2 ^ p-1")
    if d.state ~= "done" or d.pos[1] ~= 2 or d.pos[3] ~= -1 then return "a dry run that fits" end
    -- the copy beside a robot that does the same: agreement
    copy.start(r, "p1", "$0 >2 ^")
    r.sf = {id = "p1", state = "run", op = 2, pos = {2, 0, 0}, facing = "e", energy = 39990}
    copy.follow(r)
    if r.diverged then return "diverged mid-way: " .. r.diverged.why end
    r.sf = {id = "p1", state = "done", op = 3, pos = {2, 0, -1}, facing = "n", energy = 39980}
    copy.follow(r)
    if r.diverged or not r.matched then return "no agreement at the end" end
    -- a robot that ended elsewhere: a divergence, named
    copy.start(r, "p2", "$0 >")
    r.sf = {id = "p2", state = "done", op = 2, pos = {2, 0, 0}, facing = "e", energy = 39970}
    copy.follow(r)
    if not r.diverged then return "a robot ending elsewhere was not noticed" end
    return nil
end

return {run_test = run_test}
