# /home/fusion - notes for Claude (future self). Read this first.
files:
  BALANCER.txt   START HERE for fusion automation: hardware, rules, recipes, plan
  fuslib.lua     feed/run library (tested)
  layout.txt     components, sides, what is where
  components.txt old survey (fusion controllers, now disconnected)
  fluids.txt     fluid name map, tank block, pattern chest, player decisions
  recipes.txt    fusion recipes (#) + catalyst chain (C1-C4, E1-E4)
  patterns.txt   decoded chest patterns with amounts (generated)
  nbt.lua        gzip+NBT decoder library
  patterns.lua   decodes the chest patterns -> patterns.txt
  geoscan.lua/geodiff.lua  geolyzer scan + diff
  snap.lua/corr.lua  snapshot components+blocks; after a world change
                 run snap then corr: pairs block position <-> address

HOW TO READ THINGS (OC transposer API, Lua 5.3):
- find transposers: for a in component.list("transposer") ...
  component.proxy(component.get("e39e0980")) accepts the short id.
- tanks: t.getTankCount(side) ; t.getFluidInTank(side,i) ->
  {name="plasma.nitrogen", label="Nitrogen Plasma", amount=999, capacity=64000, id=287}
  empty tank -> {amount=0, capacity=64000} (no name). getFluidInTank(side) = list.
- move fluid: t.transferFluid(fromSide,toSide,amount) -> true,moved
  pushing UP from a tank-block transposer DESTROYS the fluid (void tank).
- items: t.getInventorySize(side), t.getStackInSlot(side,slot) ->
  {name, label, size, damage, tag=<gzip bytes>, ...}
  AE2FC fluid patterns also give inputs/outputs = {{name="drop of X",count=0}}
  -> display names only, count is always 0. Real data is in .tag.
- DECODE .tag: local nbt=dofile("/home/fusion/nbt.lua"); local d=nbt.decode(s.tag)
  .tag starts with 1f 8b = gzip. nbt.lua does gunzip + inflate + NBT parse,
  returns Lua tables. For fluid patterns:
    d.Inputs / d.Outputs (duplicates: d["in"], d.out) = list of entries
    entry {id=10928, Cnt=<amount mB>, tag={Fluid="<internal name>"}}
    empty slots are {} ; item ingredients would have other id, no tag.Fluid
  print with require("serialization").serialize(d)
- quick dump of the chest: lua /home/fusion/patterns.lua [outfile]

RULES: base is live. Ask the player before moving fluids/items, redstone,
overwriting files. Reading is always fine.

== STATUS 2026-10-01 (end of session) ==
Feed setup WORKS (Helium plasma D+He3 made on both MK2 and MK3): see layout.txt "FEED SETUP".
  MK3: interface 8de6c195 -> tp 784f7532 ; MK2: interface a223482e -> tp 21fd1d86
  database 9585b876: slot 3 = D cell, slot 4 = He3 cell (IC2:itemFluidCell); slots 1,2 = useless drops.
Reactor limits (main-srv, from jars): MK2 cannot run Fe, Rn, Ni, Ag, Bi, Am plasma (start 350-500M) -> MK3 only.
Mixer chain (main-srv): C1..C4 each 50000 ticks (2500 s), 1000 L each input -> 1000 L;
  EU/t 125k (ZPM) / 500k (UV) / 2M (UHV) / 8M (UEV). Mixers are the bottleneck, not plasma.
Safety: getItemsInNetwork/allItems/getCraftables/store crash the server on the MAIN ME network;
  only use them on the small fusion ME (~60 AE/t idle). getFluidsInNetwork is safe here.
GOAL (player): a balancer program: keep all 16 plasmas stocked/balanced in the fusion ME,
  run each recipe on the right reactor (MK2/MK3), and produce the 4 DT catalysts (Crude..Exotic).
  Not written yet. Inputs per recipe: recipes.txt; raw needs per Exotic batch: ~66,400 L, 20 fluids.
2026-10-01 test OK: Ti (MK2, Al+F), Sn (MK2, Ag+He3), Rn (MK3, Ir+F) 1008 L each; db slots 5 Al, 6 F, 7 Ir, 8 Ag.
  feed: one fluid per buffer tank (N/S), wait until empty; 7 runs = 1008 L of 144-L recipes.
2026-10-01 stage-1 tests: made B 2016, Zn 1512, Nb 1008 (MK2), Fe 1008 (MK3).
LESSON: each reactor has only 2 input hatches = 2 fluids at a time (1 fluid per hatch).
  So ONE recipe at a time per reactor, feed exact amounts, wait until hatches are empty.
  Leftover of one input blocks the next recipe (deadlock). fuslib.lua run() does NOT handle this yet.
STUCK (end of session): MK3 hatches probably hold leftover Mg (~8064) + Pu241 (~1008);
  MK3 buffers: N oxygen 8064, S hydrogen 14000. Calcium and Americium not made. MK3 off.
2026-10-01: after player emptied MK3 hatches + 1-slot pipes, fuslib.run (fixed sides A->N, B->S, one recipe at a time) made Ca, Am, Bi 1008 each on MK3. ALL 13 makeable plasmas tested OK. Missing inputs: Beryllium (N), Gold (Ag plasma), Potassium (Ni).
2026-10-01: N (MK2), Ag + Ni (MK3) made 1000/1008 each -> ALL 16 PLASMAS TESTED OK.
  >>> Full summary, rules and balancer plan: BALANCER.txt <<<
  fuslib.lua = working feed/run library (L.run with recipes {{A,amt},{B,amt}} per reactor).
2026-10-01 late: hardware rebuilt (pump + aux tank model). CURRENT addresses/model: BALANCER.txt 'NEW FEED MODEL' and end of layout.txt. Balancer = balancer2.lua (autostart).
