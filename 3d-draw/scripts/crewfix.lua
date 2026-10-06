--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | What a packet's end means to the crew loop (redesign/15-crew.md, "When it breaks") - kept
-- | apart from crew.lua and used through require("live"), so a new kind of end is taught by the
-- | control port's `reload crewfix` without stopping the robots: crew.lua cannot be reloaded
-- | while trips run (live looks the module up again, it does not read the file again).
-- |
-- |     crewfix.classify(last, id)    the robot's last line in the crew log, its packet ->
-- |         "done"       it finished
-- |         "look"       a place failed (the cell taken by what the map does not know, or the
-- |                      slot run dry): it looks all round, its copy set right, the plan again
-- |         "wait"       its copy's dry run met a robot: set aside a moment, no new plan
-- |         "replan"     its copies know the world changed under the plan: the plan again
-- |         "notnow"     no way there now (the others' work in the way): set aside a minute
-- |         "fail"       not understood: the robot parked as it is, for inspection
-- |     crewfix.idle(r)               a builder on no job and in no packet of the loop's ->
-- |         "resync"     its program done, only a slot count apart from its copy: the robot is
-- |                      the truth
-- |         "look"       it stopped where no loop saw it end (a restart of the loop): the stop's
-- |                      reason says a cell unknown - it looks round, its copy set right
-- |         nil          nothing to do for it
-- |     crewfix.leg(state, why)       a leg's robot on its program, its copy's divergence (or
-- |                                   nil) -> "done", "resync" (done, a slot count apart),
-- |                                   "wait" (at work; a slot count apart waited out),
-- |                                   "diverged", "stop"
-- |
-- | @date 2026-10-06
-- | ===============================================================================================
--]]

local crewfix = {}

function crewfix.classify(last, id)
    local mine = last:find(id, 1, true) ~= nil
    if mine and last:find(id .. " done", 1, true) then return "done" end
    if mine and last:find("nothing-placed", 1, true) then return "look" end
    -- a stop on a block the map did not have: it was learned, the robot looks round for more -
    -- not a failure (an unknown wall taught a cell a bump, and three bumps left the packet out,
    -- the crew's sim, 2026-10-06)
    if mine and last:find("stop blocked", 1, true) then return "look" end
    if mine and last:find("did not dry-run: wait robot", 1, true) then return "wait" end
    if mine and last:find("did not dry-run", 1, true) then return "replan" end
    if mine and last:find("NOT started", 1, true) and last:find("no way", 1, true) then
        return "notnow"
    end
    return "fail"
end

-- The stops that mean a cell the map does not know: the robot looks round, as after "look".
local UNKNOWN_CELL = {"nothing-placed", "not-expected", "blocked"}

function crewfix.idle(r)
    local why = r.diverged and tostring(r.diverged.why)
    if not why or not r.sf then return nil end
    -- done, its copy only a slot count apart or stopped on a robot gone since: as at a leg's end,
    -- the robot is the truth (Dalek_Sec idle at its park so, skipped, 2026-10-06)
    if r.sf.state == "done" and crewfix.leg("done", why) == "resync" then return "resync" end
    -- the stop's reason the robot's own, or the divergence's words (Dalek_Sec stopped
    -- nothing-placed, its divergence said only "its copy stopped at 2: robot", 2026-10-06)
    if r.sf.state == "stop" then
        local said = tostring(r.sf.why) .. " " .. why
        for _, w in ipairs(UNKNOWN_CELL) do
            if said:find(w, 1, true) then return "look" end
        end
    end
    return nil
end

-- A slot count apart is the copy missing a take or a place, not the world wrong: the robot is
-- the truth at its end, and until its end it is let work (Dalek_Sec dropped mid-packet,
-- place 0 -1 5 built unwatched and unwritten, 2026-10-06).
-- And a robot that ended done while only its copy stopped is the truth too: every op answered
-- ok in the world, the copy's world was wrong (Pintsize's place -4 0 5, all 6 steps placed, her
-- copy stopped on a torch the map does not have, parked, 2026-10-06).
function crewfix.leg(state, why)
    -- a copy stopped on a robot block its world still held (the robots move; the real one went
    -- on): as a slot count, the robot let work and the truth at its end (Dalek_Sec, place -6 0 6,
    -- 2026-10-06)
    -- and a copy's take short of the robot's: the robot stops itself on a short take, so one
    -- that went on took them all - the copy's interface was what was wrong (Baymax "took 5 of
    -- 9" at place -4 0 4, given up on and the lock let go while he still took, 2026-10-06)
    -- and a robot done while its copy still waits on a robot its world holds: the truth too
    -- (Dalek_Sec's give-back, parked, 2026-10-06)
    local w = why and tostring(why) or ""
    -- and a copy blocked by a "solid" its map learned where the robot flew on: the map was wrong
    -- (Dalek_Sec, place -2 0 6, parked at 50 of 56 steps, 2026-10-06)
    local slots = why and (w:find("^slot %d+:") or w:find("its copy stopped at %d+: robot$")
                           or w:find("its copy stopped at %d+: blocked solid$")
                           or w:find("its copy stopped at %d+: took %d+ of %d+$"))
    if why and (state == "done" or state == "halt")
            and (w:find("^the robot ended done, its copy stop")
                 or w:find("^the robot ended done, its copy wait robot")
                 or w:find("^the robot ended halt, its copy stop took %d+ of %d+$")) then
        return "resync"
    end
    if why and not slots then return "diverged" end
    if state == "done" or state == "halt" then return slots and "resync" or "done" end
    if state == "stop" then return "stop" end
    return "wait"
end

return crewfix
