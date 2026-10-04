--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | 3d-draw's view: what a robot is mapping in the real world, drawn as it happens
-- | (../3d-draw/docs/viewer.md). Run as
-- |     main.exe --scene scenes/draw3d
-- |
-- |     scene.LOG       the robot's events, appended as they arrive (3d-draw/run.py writes it)
-- |     scene.MAP       a finished map, shown when there is no log yet
-- |     scene.EXTEND    the columns painted for the robot to map next
-- |     scene.PLAN      a building to show over the terrain
-- |     scene.PENDING   what is left of a build, shown with J
-- |     scene.LABELS    names shown over blocks
-- |     scene.MARKERS   coloured markers the user puts on blocks (K), for Claude to read
-- |     scene.CHUNKS, ANCHOR, ZONE   the map by chunk, for the map of chunks (M)
-- |     scene.discover  main.lua calls it on every scene; this one has no parts to find
-- |
-- | @date 2026-10-04
-- | ===============================================================================================
--]]

local scene = {}

scene.NAME = "3d-draw"

-- Relative to the simulator's folder, where main.exe runs. Both are under 3d-draw/data/, which is
-- gitignored: they are read from the user's world.
scene.LOG = "../3d-draw/data/live.log"
scene.MAP = "../3d-draw/data/map.txt"

-- The columns painted for the robot to map next, `x z` per line (3d-draw/run.py --extend).
scene.EXTEND = "../3d-draw/data/extend.txt"

-- Buildings to show over the terrain (H), one block per line; 3d-draw/design/ writes them. The
-- house is not one any more: finished, it is in the map itself (3d-draw/imprint.py, 2026-10-04).
-- The village south of the house (3d-draw/design/village.py): cottages, a wheat field, a windmill.
scene.PLAN = {"../3d-draw/data/harbour.txt", "../3d-draw/data/village.txt"}

-- What is left of a build (J), `p x y z status name` per line, rewritten by the build agent
-- every 30 s: one file, or one per plan. A `*` in a file name matches what its folder holds.
scene.PENDING = {"../3d-draw/data/pending.txt", "../3d-draw/data/pending-*.txt"}

-- Names shown over blocks, `label x y z text` per line: the station, what to build around.
scene.LABELS = "../3d-draw/data/labels.txt"

-- Markers the user places on blocks (K), `marker x y z colour [note]` per line: what a thing is,
-- told without reading coordinates (the user, 2026-10-04).
scene.MARKERS = "../3d-draw/data/markers.txt"

-- The map kept by chunk (3d-draw/zones.py): the chunk files, their overview, and where the start
-- block is in the world. M shows the chunks; a click shows the 3x3 round one.
scene.CHUNKS = "../3d-draw/data/chunks"
scene.ANCHOR = "../3d-draw/data/anchor.txt"
scene.ZONE = "../3d-draw/data/zone.txt"
-- Laid over the chunks of the zone shown, in this order, as zones.py does: what the robots
-- built and finished (imprint.py), and the blocks the user told of. The zone is drawn again
-- when any of its files changes.
scene.BUILT = "../3d-draw/data/built.txt"
scene.FIXED = "../3d-draw/data/fixed.txt"
-- Every block kind's one number (3d-draw/zones.py): what a live log's id means when it never said.
scene.REGISTRY = "../3d-draw/data/palette.txt"

function scene.discover(w)
    return {}, {}
end

return scene
