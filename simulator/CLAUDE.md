# CLAUDE.md — the OpenComputers simulator

Instructions for working in `simulator/`. Written 2026-09-17 after a run of bugs that all had the
same shape.

## The reference is the mod, not your judgement

**This project emulates OpenComputers and Minecraft. Their behaviour is the specification. Yours is
not.** When a question comes up about how something behaves — how a component is found, what a
screen shows, what a key event carries, when a filesystem is writable — the answer is in the mod's
own files, and reading them takes a minute.

Do not reason from what seems sensible. Every bug below came from exactly that, and each one looked
perfectly reasonable while it was being written:

- **Components were gathered once, at boot.** "A computer is the sum of what is plugged in when you
  press the button" is a defensible design. It is not OpenComputers', which fires `component_added`
  and `component_removed` at runtime. A transposer placed against a running computer was plainly
  there and plainly invisible. Everything is hot swappable, always.
- **A screen was drawn as a scrolling log**, showing the last rows that fit. A screen is a fixed
  grid; `edit` puts the file at the top and its status bar on the last row. The top was cropped, so
  a file being typed was invisible while the status bar underneath looked perfectly alive.
- **The cursor was thought to be missing.** OpenComputers has no cursor. A terminal draws one by
  swapping a cell's two colours. Reading only characters out of the grid threw it away.
- **Key events carried a code of zero.** A program identifies a key by its scancode, not by the
  character: `bin/edit.lua` matches its whole keymap with `code == keyboard.keys[key]`, and
  `lib/core/cursor.lua` leaves `lua` on ctrl plus `code == keys.d`. Neither could match anything.
- **`computer.beep` was assumed to be a host function.** It is not; `machine.lua` defines it as
  `component.invoke(computer.address(), "beep")`, so the computer block has to exist as a component
  of its own machine.

In every case the mod's own source said so plainly.

## How to check

The jars are the source of truth and both are already on the machine. Read them directly:

```
python -c "import zipfile; z=zipfile.ZipFile(JAR); print(z.read(NAME).decode())"
```

- `mods/OpenComputers-1.8.0.13-GTNH.jar`
  - `assets/opencomputers/lua/machine.lua` — the sandbox and the host contract
  - `assets/opencomputers/lua/bios.lua` — the default EEPROM
  - `assets/opencomputers/loot/openos/**` — the whole operating system, 179 files
  - `assets/opencomputers/lang/en_US.lang` — item names and tiers, for anything user-facing
  - `assets/opencomputers/textures/blocks/**`
- the vanilla jar, for blocks that are Minecraft's rather than the mod's

Local `unzip` on Windows silently extracted 27 of 179 files once. Use python's `zipfile`.

## The layering, and why

- **C++ owns** the cell matrix, the renderer, the asset loading, and the component implementations.
- **Lua owns** the interface, what a click does, the world file, and which components a machine
  should have.
- **A guest machine gets a raw `lua_State`, never a virt_composer one.** The guest is emulated code.
  Letting it see `vc` would hand a simulated computer the keys to the simulator.
- `cell_t` is a leaf, deliberately: a kind, a state, a facing, a position, and `u` for whatever the
  script layer wants. **A new per-block field goes in `u`**, not in C++.

## Testing

**Test the path a person actually takes.** Three separate bugs survived a passing test because the
test called the helper underneath the thing that was broken:

- the terminal was driven through `machines.send_key` directly, never through the ImGui pairing;
- `machines.screen_output` was tested, never `ui.miniscreen`, which returns early unless a screen is
  under the crosshair;
- the editor was tested with real scancodes, never with what the live path was actually sending.

Where the real path needs input, drive it: ImGui accepts injected key and character events, and a
frame-by-frame script can type into a running machine. That harness found the answer in one run
after three rounds of reasoning had not.

Verify against the screen's own contents, not against "it did not crash".

## Building

`make`. Needs `cl` on the PATH.

**Close the running simulator before rebuilding.** The link fails with `LNK1168: cannot open
main.exe for writing` while it is open, and the build then *appears* to succeed — leaving the old
binary running new scripts. The symptom is `class id ... doesn't have member: <name>`: the exe is
behind the Lua.

`Failed to execute loaded script` with no line number is a Lua **syntax** error, not a runtime one.

## Style

- 100 columns, code and comments alike.
- A comment block stays attached to every function; say what it does and why it is that way, not
  how. Where a decision came from the mod's behaviour, say so — that is what stops the next session
  reverting it to something more reasonable.
- Where a bug was subtle, record the symptom at the fix. Several comments here exist to stop a
  plausible-looking change being made again.
