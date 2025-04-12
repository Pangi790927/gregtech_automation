local term      = require("term")
local sides     = require("sides")
local component = require("component")

local gpu = component.gpu

local egen = component.proxy(component.get("6133"))
local eraf = component.proxy(component.get("cad2"))
local void = component.proxy(component.get("a0de"))
local me   = component.me_interface
local easm = component.proxy(component.get("533d"))

-- 10 minute avarage
local average_cnt = 60*10;

egen.local_name = "egen"
eraf.local_name = " raf"
void.local_name = "void"
easm.local_name = " asm"

egen.lta_in = 0
eraf.lta_in = 0
void.lta_in = 0
easm.lta_in = 0

egen.lta_out = 0
eraf.lta_out = 0
void.lta_out = 0
easm.lta_out = 0

-- term.getViewport() -> WxH = 160/50

local incrementer_cnt = 0
function update_incrementer()
    incrementer_cnt = incrementer_cnt + 1
end

function update_battery(b)
    b.lta_in = (b.getEUInputAverage() + b.lta_in * average_cnt) / (average_cnt + 1)
    b.lta_out = (b.getEUOutputAverage() + b.lta_out * average_cnt) / (average_cnt + 1)
end

local fluids_state = {}
function update_fluids()
    fluids = me.getFluidsInNetwork()
    if  fluids_state.fluids == nil then
        fluids_state.fluids = {}
    end
    if fluids_state.fluid_cnt == nil then
        fluids_state.fluid_cnt = 0
    end
    if fluids_state.index == nil then
        fluids_state.index = 0
    end
    for i=1, #fluids do
        label = fluids[i].label
        amount = fluids[i].amount
        if fluids_state.fluids[label] == nil then
            -- didn't have this fluid, init it
            fluids_state.fluids[label] = {}
            fluids_state.fluids[label].amount = amount
            fluids_state.fluids[label].amount60 = 0
            fluids_state.fluids[label].amount600 = 0
            fluids_state.fluids[label].amount3600 = 0
            fluids_state.fluids[label].last_amount60 = amount
            fluids_state.fluids[label].last_amount600 = amount
            fluids_state.fluids[label].last_amount3600 = amount
            fluids_state.fluids[label].cnt60 = 60
            fluids_state.fluids[label].cnt600 = 600
            fluids_state.fluids[label].cnt3600 = 3600
            fluids_state.fluids[label].show = false
        end
        fluids_state.fluids[label].amount = amount
        if amount > 1000000 then
            if fluids_state.fluids[label].show == false then
                fluids_state.fluid_cnt = fluids_state.fluid_cnt + 1
            end
            fluids_state.fluids[label].show = true
        end
        if amount < 1000000 then
            fluids_state.fluids[label].cnt60 = 60
            fluids_state.fluids[label].cnt600 = 600
            fluids_state.fluids[label].cnt3600 = 3600
            fluids_state.fluids[label].last_amount60 = amount
            fluids_state.fluids[label].last_amount600 = amount
            fluids_state.fluids[label].last_amount3600 = amount
        end
        fluids_state.fluids[label].cnt60 = fluids_state.fluids[label].cnt60 - 1
        fluids_state.fluids[label].cnt600 = fluids_state.fluids[label].cnt600 - 1
        fluids_state.fluids[label].cnt3600 = fluids_state.fluids[label].cnt3600 - 1
        if fluids_state.fluids[label].cnt60 == 0 then
            fluids_state.fluids[label].cnt60 = 60
            fluids_state.fluids[label].amount60 = amount - fluids_state.fluids[label].last_amount60
            fluids_state.fluids[label].last_amount60 = amount
        end
        if fluids_state.fluids[label].cnt600 == 0 then
            fluids_state.fluids[label].cnt600 = 600
            fluids_state.fluids[label].amount600 = amount - fluids_state.fluids[label].last_amount600
            fluids_state.fluids[label].last_amount600 = amount
        end
        if fluids_state.fluids[label].cnt3600 == 0 then
            fluids_state.fluids[label].cnt3600 = 3600
            fluids_state.fluids[label].amount3600 = amount - fluids_state.fluids[label].last_amount3600
            fluids_state.fluids[label].last_amount3600 = amount
        end
    end
end

function battery_status(b, line)
    local text1 = string.format("%5s               energy: %15d/%15d",
            b.local_name,
            b.getEUStored(), b.getEUMaxStored())
    local text2 = string.format("                    in/out: %15d/%15d",
            b.getEUInputAverage(), b.getEUOutputAverage())
    local text3 = string.format("      10-minute-avg-in/out: %15.3f/%15.3f",
            b.lta_in, b.lta_out)

    term.setCursor(1, line)
    term.write(text1)
    term.setCursor(1, line+1)
    term.write(text2)
    term.setCursor(1, line+2)
    term.write(text3)
end

function incrementer_status(line)
    term.setCursor(1, line)
    text = string.format("increments since alive: %d", incrementer_cnt)
    term.write(text)
end

function fluids_print_val(pos_x, pos_y, val, is_diff)
    if (not is_diff) and val < 2 then
        gpu.setForeground(0xFF0000)
    elseif (not is_diff) then
        gpu.setForeground(0xFFFFFF)
    elseif val > 0.1 then
        gpu.setForeground(0x00FF00)
    elseif val < -0.1 then
        gpu.setForeground(0xFF0000)
    else
        gpu.setForeground(0xFFFFFF)
    end
    term.setCursor(pos_x, pos_y)
    term.write(string.format("%11.3f", val))
end

function fluids_status()
    -- there are 25 lines
    -- 1 line for splitter
    -- 1 line for header
    -- 1 line for extra info
    local fluid_on_page = 20
    local pages = math.ceil(fluids_state.fluid_cnt / fluid_on_page)

    -- stay for 10 seconds on each page
    local page = (fluids_state.index // 10) % pages

    term.setCursor(1, 1)
    term.write(string.format("page: %d/%d", page + 1, pages))
    term.setCursor(1, 2)
    term.write("                          Name  Amount[ML]      ML/60s     ML/600s    ML/3600s ")
    term.setCursor(1, 3)
    gpu.setForeground(0x999999)
    term.write("-------------------------------------------------------------------------------")
    gpu.setForeground(0xFFFFFF)
    
    fluids_state.index = fluids_state.index + 1
    local index = 1
    for name, fluid in pairs(fluids_state.fluids) do
        if fluid.show then
            if index > page * fluid_on_page then
                local lindex = index - page * fluid_on_page
                local M = 1000000
                local text = string.format("%30s %11.3f %11.3f %11.3f %11.3f", name, fluid.amount/M, fluid.amount60/M, fluid.amount600/M, fluid.amount3600/M)
                term.setCursor(1, 3 + lindex)
                term.write(string.format("%30s", name))

                fluids_print_val(32, 3 + lindex, fluid.amount/M, false)
                fluids_print_val(44, 3 + lindex, fluid.amount60/M, true)
                fluids_print_val(56, 3 + lindex, fluid.amount600/M, true)
                fluids_print_val(68, 3 + lindex, fluid.amount3600/M, true)
                
                gpu.setForeground(0xFFFFFF)
            end
            if index > (page + 1) * fluid_on_page then
                break
            end
            index = index + 1
        end
    end
end

local slider = 0
gpu.setResolution(80, 25)
gpu.setDepth(8)
while true do
    update_incrementer()
    update_battery(egen)
    update_battery(easm)
    update_battery(eraf)
    update_battery(void)
    update_fluids()
    
    slider = (slider + 1) % 40
    term.clear()
    
    if slider >= 10 then
        fluids_status()
    else
        incrementer_status(2)
        battery_status(egen, 4)
        battery_status(easm, 8)
        battery_status(eraf, 12)
        battery_status(void, 16)
    end
    
    os.sleep(1)
end