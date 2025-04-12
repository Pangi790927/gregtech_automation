local term      = require("term")
local sides     = require("sides")
local component = require("component")

local gpu = component.gpu

local egen = component.proxy(component.get("6133"))
local eraf = component.proxy(component.get("cad2"))
local void = component.proxy(component.get("fcf8"))
local me   = component.proxy(component.get("ce6c"))
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

function battery_status(b, line)
    b.lta_in = (b.getEUInputAverage() + b.lta_in * average_cnt) / (average_cnt + 1)
    b.lta_out = (b.getEUOutputAverage() + b.lta_out * average_cnt) / (average_cnt + 1)

    text1 = string.format("%5s               energy: %15d/%15d",
            b.local_name,
            b.getEUStored(), b.getEUMaxStored())
    text2 = string.format("                    in/out: %15d/%15d",
            b.getEUInputAverage(), b.getEUOutputAverage())
    text3 = string.format("      10-minute-avg-in/out: %15.3f/%15.3f",
            b.lta_in, b.lta_out)

    term.setCursor(1, line)
    term.write(text1)
    term.setCursor(1, line+1)
    term.write(text2)
    term.setCursor(1, line+2)
    term.write(text3)
end

local incrementer_cnt = 0
function incrementer(line)
    incrementer_cnt = incrementer_cnt + 1
    term.setCursor(1, line)
    text = string.format("increments since alive: %d", incrementer_cnt)
    term.write(text)
end

gpu.setResolution(80, 25)
while true do
    term.clear()
    incrementer(2)
    battery_status(egen, 4)
    battery_status(easm, 8)
    battery_status(eraf, 12)
    battery_status(void, 16)
    os.sleep(1)