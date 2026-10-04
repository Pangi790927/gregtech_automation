-- patterns.lua: decode AE2FC fluid patterns in the chest (UP of transposer 61501976)
-- usage: patterns [outfile]   (read-only; prints and optionally writes a file)
local nbt=dofile("/home/fusion/nbt.lua")
local component=require("component")
local args={...}
local tp=component.proxy(component.get("61501976"))
local SIDE=1 -- UP
local function fmt(list,disp)
  local r={}
  for i,e in ipairs(list or {}) do
    if e.id then
      if e.tag and e.tag.Fluid then
        r[#r+1]=e.Cnt.." L "..e.tag.Fluid
      else -- item ingredient (id is numeric item id)
        r[#r+1]=(e.Cnt or e.Count).."x item#"..e.id..":"..(e.Damage or 0)
          ..(disp and disp[i] and disp[i].name and (" ("..disp[i].name..")") or "")
      end
    end
  end
  return table.concat(r," + ")
end
local lines={}
for slot=1,tp.getInventorySize(SIDE) do
  local s=tp.getStackInSlot(SIDE,slot)
  if s and s.tag then
    local ok,t=pcall(nbt.decode,s.tag)
    if ok then
      lines[#lines+1]=string.format("%2d: %s -> %s",slot,fmt(t.Inputs or t["in"],s.inputs),fmt(t.Outputs or t.out,s.outputs))
    else lines[#lines+1]=slot..": decode error "..tostring(t) end
  end
end
local txt=table.concat(lines,"\n")
print(txt)
if args[1] then local f=io.open(args[1],"w") f:write(txt.."\n") f:close() end
