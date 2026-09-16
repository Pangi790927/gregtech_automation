--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | A SAVE IS A DIRECTORY, and this module is the only thing that knows
-- | its shape. Nothing else builds a path into it.
-- |
-- |     saves.dir()             the save directory itself
-- |     saves.level_path()      the map and the camera, one file
-- |     saves.settings_path()   the settings, another file
-- |     saves.disk_dir(addr)    one hard disk, as a real folder of real files
-- |     saves.prepare()         makes the directory tree, before anything writes
-- |     saves.legacy(name)      where a pre-directory save used to sit
-- |     saves.readable(p, l)    that one, when the directory has nothing yet
-- |
-- | --- internal, not on the module table -------------------------------------------------------
-- |     DATA_PREFIX, SAVE_DIR
-- |
-- | @date 2026-09-17 14:00
-- | ===============================================================================================
--]]

local vc = require("virt_composer")

local saves = {}

--[[ Prefixed by app_mode.h: nothing in the real instance, `test_run/` under --test. A test that
boots a machine and types into it would otherwise overwrite a real world and a real hard disk.
@date 2026-09-17 ]]
local DATA_PREFIX = (vc.app_data_prefix and vc.app_data_prefix()) or ""

--[[ The name of the directory a save lives in. One save, so one name; multiple worlds would make
this an argument, and nothing about the layout below would have to change to allow it. ]]
local SAVE_DIR = "save"

--[[ @brief The save directory, absolute.
-- |
-- | Resolved app-local like everything else, so it sits beside the executable rather than wherever
-- | the process happened to be launched from.
-- |
-- | @return string
-- |
-- | @date 2026-09-17 14:00
--]]
function saves.dir()
    return vc.path_resolve(DATA_PREFIX .. SAVE_DIR)
end

--[[ @brief The map and the camera.
-- |
-- | One file, because there is one of it: this world has no chunks to split across regions the way
-- | Minecraft's does, so a single readable list of cells is the whole map.
-- |
-- | @return string
-- |
-- | @date 2026-09-17 14:00
--]]
function saves.level_path()
    return saves.dir() .. "/level.save"
end

--[[ @brief The settings.
-- |
-- | Separate from the map because it is a different kind of thing: where Minecraft is installed and
-- | whether to autosave are not facts about the world, and losing a world should not take them.
-- |
-- | @return string
-- |
-- | @date 2026-09-17 14:00
--]]
function saves.settings_path()
    return saves.dir() .. "/settings.save"
end

--[[ @brief Where the hard disks live, all of them.
-- |
-- | Named `opencomputers` after the folder the mod keeps its filesystems in, for the same reason it
-- | does: everything under here is a guest's data rather than the world's.
-- |
-- | @return string
-- |
-- | @date 2026-09-17 14:00
--]]
function saves.disks_dir()
    return saves.dir() .. "/opencomputers"
end

--[[ @brief One hard disk's folder.
-- |
-- | Named by the filesystem's address, which is how the mod does it - a folder per filesystem, its
-- | real files inside, editable with a text editor. The address is kept with the computer (see
-- | world.lua's level format) so the same disk finds the same folder on the next load.
-- |
-- | @param address  string
-- | @return string
-- |
-- | @date 2026-09-17 14:00
--]]
function saves.disk_dir(address)
    return saves.disks_dir() .. "/" .. address
end

--[[ @brief Makes the directory tree, so a writer can just open its file.
-- |
-- | Called before anything saves. Creating the directory at the moment of writing instead would put
-- | the same three lines in every writer, and a writer that forgot would fail with a missing-file
-- | error that says nothing about the real cause.
-- |
-- | @return boolean - whether the directory is there afterwards
-- |
-- | @date 2026-09-17 14:00
--]]
function saves.prepare()
    return vc.path_make_dirs(saves.disks_dir())
end

--[[ @brief Where a save from before the directory existed sits.
-- |
-- | The first version of this wrote world.save, disks.save and settings.save flat beside the
-- | executable. Those files still exist on any machine that ran it, one of them holding a whole
-- | installed operating system, so the readers fall back to them when the directory has nothing
-- | yet. Nothing writes here any more - the next save lands in the directory, and the old file is
-- | left alone as its own backup.
-- |
-- | @param name  string - "world.save", "disks.save" or "settings.save"
-- | @return string
-- |
-- | @date 2026-09-17 14:00
--]]
function saves.legacy(name)
    return vc.path_resolve(DATA_PREFIX .. name)
end

--[[ @brief The path to read one of the save's files from: the directory's copy when it is there,
-- | and the pre-directory one when it is not.
-- |
-- | What makes the move to a directory invisible to whoever was running the earlier version. The
-- | first load finds nothing in the directory and reads the old flat file; the first save writes the
-- | directory; every load after that finds it. Nothing is moved or deleted, so the old file stays as
-- | its own backup.
-- |
-- | @param path    string - where it lives now
-- | @param legacy  string - what it used to be called, beside the executable
-- | @return string
-- |
-- | @date 2026-09-17 14:00
--]]
function saves.readable(path, legacy)
    local file = io.open(path, "r")
    if file then
        file:close()
        return path
    end
    return saves.legacy(legacy)
end

return saves
