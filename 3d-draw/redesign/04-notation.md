04 - the notation of a program (exec)
======================================

What `exec` and `give_way` carry (03-exec.md). Agreed with the user, 2026-10-05, to be parsed
uniquely ("the rest ok as long as you can parse them uniquely").

A program starts with `$<cost>`, the energy of its way home, or `$home` for the way home
itself. It may then give its palette, `{name:meta,name:meta,...}`, numbered from 1; `x` names
its block by that number. `name:*` matches any meta (a leaf's decay bits, a log's turn).

Whitespace is ignored. An op starts with a step character or a letter; whatever follows an op
belongs to it until the next step character or letter. Optional parts each start with their own
mark (`/ ! * .`), which never starts an op, so every program parses one way only.

| Op | Means | Example |
|---|---|---|
| `^ v > < + -` then a count | step north, south, east, west, up, down; the count repeats it | `>3^2` = 3 east, 2 north |
| `f<dir>` | turn to face | `f>` |
| `x<dir><block>` | dig, only if the block there is that one of the program's palette | `x-2` |
| `p<dir><slot>[/<face>][!]` | put from a slot, clicking that face, sneaking with `!`; result: what stands there | `p-3`, `p>12/^!` |
| `u<dir>[<slot>][/<face>][!]` | use, with the tool from that slot, put back after | `u-7/^` |
| `t<dir><their>.<mine>[*<n>]` | take from what is in front into its own slot | `t>2.5*64` |
| `g<dir><mine>[*<n>]` | give a slot into what is in front | `g>9` |
| `s<from>.<to>[*<n>]` | shift between its own slots | `s4.1*1` |
| `c<slot>[*<n>]` | craft into that slot | `c16*4` |
| `l<dir>` | look at one block; result: name meta | `l-` |
| `z[<percent>]` | wait until energy is that share of the maximum (95 if none), sleeping: at a charger, or under the sun on its solar panel (the user: "maybe also a "wait recharge" step in the state machine (they have solar pannels)") | `z90` |
| `@1`, `@0` | chunkloader on, off | `@1` |
| `h` | halt: wait for the PC | `+ h` |

Example, to the ME and back to a row:

```
exec 41 $1800 {minecraft:dirt:0,minecraft:tallgrass:*}
        <3^2 x<2 f> t>1.1*64 t>2.2*32 v>7 p-1 > p-1 > p-2 > p-2 > p-3
```

