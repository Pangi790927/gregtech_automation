02 - the robot's commands: 28 today, fewer proposed
====================================================

The user, 2026-10-05: "tell me all of them, I think there are too many and making less would
enforce better comms". PROPOSAL, not made; the user decides.

## The 28 today (robot/server.lua), and who on the PC uses them

| Command | Does | Used by |
|---|---|---|
| hello | x y z facing energy max slots durability | builders, rlink |
| pos | x y z facing | rlink |
| energy | energy max | builders, name, survey |
| setpos x y z | tells a new robot where it is | nobody |
| tanks | tank count (read-only, 2026-10-04) | nobody (asked by hand) |
| sys | uptime, memory (read-only, 2026-10-04) | nobody (asked by hand) |
| move dir [home] [wet] | one step | builders, craft, rlink, survey |
| face dir | turn to a side | craft, me |
| back | walk its own trail home | rlink |
| detect dir | solid kind | nobody |
| analyze dir | name meta hardness | builders, name, survey |
| scan dx dz [dy] [h] | a geolyzer column | builders, survey |
| swing dir [home] | break the block | builders, name, rlink, survey |
| place dir [face] [slot] [sneak] | place from the selected slot | builders |
| use dir [face] [sneak] | right-click (a hoe, a door) | builders |
| select slot | choose a slot | builders, me |
| stack slot | what is in a slot | nobody |
| inventory | every non-empty slot | builders, me |
| suck dir [n] | take from what is in front | nobody |
| suckslot dir slot [n] | take from that slot of it | me |
| drop dir [n] | give to what is in front | nobody |
| dropslot dir slot [n] | give into that slot of it | me |
| equip | swap selected slot and tool | builders |
| transfer from to [n] | move items between own slots | craft |
| craft slot [n] | craft from the grid | craft |
| chunk on/off | chunkloader upgrade | survey, zones |
| wait s | sleep on the robot | me |
| charge [share] [s] | wait at the charger until full | builders, rlink, survey |

7 are used by nobody; `move` is sent once per step, so a 60-step walk is 60 lines.

## Next: three commands (03-exec.md)

A set of 12 was proposed here first, with one `status` for the many (the user, 2026-10-05: "there
is no need for so many status commands, a single status will return all of those, the pc will
cache and simulate the same thing as the robot"). The user then folded every action into one
serialized program, `exec`; the robot became a state machine. That design is `03-exec.md`.
