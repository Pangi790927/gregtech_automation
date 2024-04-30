s = require("sides")

component = {
	redstone={}
}

function component.redstone.setOutput(side, val)
	component.redstone[side] = val	
end

function create_transposer()
	local transp = {}
	return transp
end

l1 = { label="red_lens", size=2, maxSize=64 }
l2 = { label="green_lens", size=2, maxSize=64 }
l3 = { label="blue_lens", size=2, maxSize=64 }
l4 = { label="white_lens", size=2, maxSize=64 }
pan = { label="pannel", size=64, maxSize=64 }
cl1 = { label="ic2cell", size=64, maxSize=64 }
cl2 = { label="ic2cell", size=64, maxSize=64 }
cl3 = { label="ic2cell", size=64, maxSize=64 }
c1 =  { label="circ1", size=2, maxSize=64}
c2 =  { label="circ2", size=2, maxSize=64}
c3 =  { label="circ3", size=2, maxSize=64}
c4 =  { label="circ4", size=2, maxSize=64}
c5 =  { label="circ5", size=2, maxSize=64}
c6 =  { label="circ6", size=2, maxSize=64}
c7 =  { label="circ7", size=2, maxSize=64}
c8 =  { label="circ8", size=2, maxSize=64}
c9 =  { label="circ9", size=2, maxSize=64}
c10 = { label="circ10", size=2, maxSize=64}
c11 = { label="circ11", size=2, maxSize=64}
c12 = { label="circ12", size=2, maxSize=64}
c13 = { label="circ16", size=2, maxSize=64}
c14 = { label="circ19", size=2, maxSize=64}
c15 = { label="circ20", size=2, maxSize=64}
c16 = { label="circ24", size=2, maxSize=64}
e1 =  { label="extruder1", size=2, maxSize=64}
e2 =  { label="extruder2", size=2, maxSize=64}
e3 =  { label="extruder3", size=2, maxSize=64}
e4 =  { label="extruder4", size=2, maxSize=64}
e5 =  { label="extruder5", size=2, maxSize=64}
e6 =  { label="extruder6", size=2, maxSize=64}
e7 =  { label="extruder7", size=2, maxSize=64}
e8 =  { label="extruder8", size=2, maxSize=64}
e9 =  { label="extruder9", size=2, maxSize=64}
e10 = { label="extruder10", size=2, maxSize=64}
e11 = { label="extruder11", size=2, maxSize=64}
e12 = { label="extruder12", size=2, maxSize=64}

cchest = {
	nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
	nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
	nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
	nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
	nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
	nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
	l1 , l2 , l3 , l4 , pan, cl1, cl2, cl3, c1 , c2 , c3 , c4 ,
	c5 , c6 , c7 , c8 , c9 , c10, c11, c12, c13, c14, c15, c16,
	e1 , e2 , e3 , e4 , e5 , e6 , e7 , e8 , e9 , e10, e11, e12,
}

transp_a = {
	[s.south] = cchest
}
transp_b = {}
transp_c = {}

function transp_a.getStackInSlot(side, slot)
	return transp_a[side][slot]
end

component["6861"] = transp_a
component["a85a"] = transp_b
component["7c02"] = transp_c

function component.get(str)
	return component[str]
end

function component.proxy(o)
	return o
end

return component
