--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | A text file followed cheaply: its size looked at every second, its whole text read when the
-- | size changed, and every 10 s for an edit of the same length (a new plan can be exactly as
-- | long as the last: the user, 2026-10-04, wanted reloads "without me needing to close the app").
-- |
-- |     local w = watch.new(paths)   one file or a list of them, read as one text
-- |     w:poll(dt)                   the new text when it changed, else nil
-- |     w:text()                     the text as last read
-- |     w:mark(text)                 takes `text` as read: a file this program just wrote
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local watch = {}
watch.__index = watch

local function size_of(path)
    local f = io.open(path, "rb")
    if not f then return -1 end
    local n = f:seek("end")
    f:close()
    return n
end

local function read_all(paths)
    local all = {}
    for _, p in ipairs(paths) do
        local f = io.open(p, "rb")
        all[#all + 1] = f and f:read("a") or ""
        if f then f:close() end
    end
    return table.concat(all, "\n")
end

local function sizes(paths)
    local out = {}
    for i, p in ipairs(paths) do out[i] = size_of(p) end
    return table.concat(out, ",")
end

function watch.new(paths)
    if type(paths) ~= "table" then paths = {paths} end
    return setmetatable({paths = paths, size = nil, last = nil, tick = 1e9, full = 0}, watch)
end

function watch:poll(dt)
    self.tick, self.full = self.tick + dt, self.full + dt
    if self.tick < 1.0 then return nil end
    self.tick = 0
    local s = sizes(self.paths)
    local full = self.full >= 10.0
    if s == self.size and not full then return nil end
    if full then self.full = 0 end
    self.size = s
    local t = read_all(self.paths)
    if t == self.last then return nil end
    self.last = t
    return t
end

function watch:text()
    return self.last or ""
end

function watch:mark(text)
    self.last, self.size = text, sizes(self.paths)
end

return watch
