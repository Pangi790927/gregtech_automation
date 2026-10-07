-- Dry-run one packet's program from station 1's spot on the copies' world, a stand-in robot
-- holding its whole bill (slot k for the k-th kind); prints where it stops and the last ops.
-- ID: the packet's id, a global set before the dofile (redesign/19-ops.md).
local crew, copy, programs, packets = require("crew"), require("copy"), require("programs"),
    require("packets")
local me = require("me")
local id = ID or "place -1 0 7"
local p = packets.result.packets[id]
local st = me.stations[1]
local place = crew.bill(p)
local slots, kinds, n = {}, {}, 0
for kk, c in pairs(place) do
    local name, meta = kk:match("^(.+):(%d+)$")
    n = n + 1
    slots[n] = {name = name, meta = tonumber(meta), count = c}
    kinds[kk] = n
end
local r = {name = "dryprobe", sf = {pos = {st.SPOT[1], st.SPOT[2], st.SPOT[3]}, facing = st.FACE,
           energy = 40000}, slots = slots}
local text, a2, _, opstep = programs.make(p, {pos = r.sf.pos, facing = st.FACE,
    slot_of = function(nm, meta)
        local iname, imeta = crew.item(nm, meta)
        return kinds[iname .. ":" .. imeta]
    end, avoid = {}}, {want = packets.want})
if not text then return "no program: " .. tostring(a2) end
local d = copy.dry(r, text)
local out = {("%s: %s %s at %s, %d ops"):format(id, tostring(d.state), tostring(d.why),
             table.concat(d.pos or {}, ","), d.ops or -1)}
local h = d.hist or {}
for i = math.max(1, #h - 6), #h do out[#out + 1] = tostring(h[i]) end
local m = require("machine").parse(text)
local last = h[#h] and tonumber(tostring(h[#h]):match("^(%d+)"))
if last and m.ops[last] then
    local op = m.ops[last]
    local t = {}
    for k, v in pairs(op) do t[#t + 1] = k .. "=" .. tostring(v) end
    out[#out + 1] = "op " .. last .. ": " .. table.concat(t, " ")
end
if last and m.ops[last] and m.ops[last].block then
    local pe = m.palette[m.ops[last].block]
    out[#out + 1] = ("its palette entry: %s:%s"):format(tostring(pe and pe.name),
            tostring(pe and pe.meta))
end
return table.concat(out, "\n")
