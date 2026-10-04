--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | NOTHING. The testing instance's entry script (3d-draw_test.yaml): main.cpp --test calls
-- | sim_test(), which runs every tests/lua/test_*.lua - each exposing one run_test() that returns
-- | nil on success or a string saying what failed - and returns 0 when all passed.
-- |
-- | Laid out as math_writer's tests are (3d-draw/redesign/06-pc.md). Files a test writes go
-- | under test_run/, which only the testing instance uses.
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

package.path = package.path .. ";./scripts/?.lua;../simulator/scripts/?.lua;./tests/lua/?.lua"
    .. ";./robot/?.lua"

local vc = require("virt_composer")

function sim_test()
    if not vc.app_is_testing() then
        print("sim_test refused: this is not the testing instance")
        return 1
    end
    local names = vc.path_list_dir("tests/lua")
    table.sort(names)
    local failures, ran = 0, 0
    for _, n in ipairs(names) do
        local mod = n:match("^(test_.+)%.lua$")
        if mod then
            ran = ran + 1
            local ok, t = pcall(require, mod)
            local why
            if not ok then
                why = "would not load: " .. tostring(t)
            else
                local fine, res = pcall(t.run_test)
                why = not fine and ("threw: " .. tostring(res)) or res
            end
            if why then
                failures = failures + 1
                print(("FAIL %s: %s"):format(mod, why))
            else
                print(("ok   %s"):format(mod))
            end
        end
    end
    print(("%d test(s), %d failure(s)"):format(ran, failures))
    return (failures == 0 and ran > 0) and 0 or 1
end
