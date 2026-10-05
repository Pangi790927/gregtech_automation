--[[ Every module of the program loads (a syntax error in one shows here, not in the window),
-- and a followed file is seen when it changes (scripts/watch.lua).
-- @date 2026-10-05 ]]

local function write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

local function run_test()
    for _, m in ipairs({"watch", "chunks", "look", "view", "plan", "marks", "labels", "zmap",
                        "relay", "copy", "robots", "control", "packets", "planner", "route",
                        "programs", "sim", "prove", "crew", "me", "recipes"}) do
        local ok, err = pcall(require, m)
        if not ok then return m .. " would not load: " .. tostring(err) end
    end
    local watch = require("watch")
    local path = "test_run/watched.txt"
    write(path, "one\n")
    local w = watch.new(path)
    if w:poll(0) ~= "one\n" then return "the first poll did not read the file" end
    if w:poll(5) ~= nil then return "an unchanged file was read as news" end
    write(path, "one\ntwo\n")
    if w:poll(0.5) ~= nil then return "polled again within a second" end
    if w:poll(0.6) ~= "one\ntwo\n" then return "a longer file was not seen" end
    write(path, "ONE\nTWO\n")
    if w:poll(1.0) ~= nil then return "a same-size edit seen before 10 s" end
    if w:poll(9.0) ~= "ONE\nTWO\n" then return "a same-size edit missed after 10 s" end
    w:mark("mine")
    return nil
end

return {run_test = run_test}
