--[==[ claude - talks with Claude, which runs on the user's PC through
claude-oc.exe and can use this computer: run its programs and Lua, read and
write its files. Installed by the claude-oc zone as /home/bin/claude.lua,
anew each time claude-oc.exe attaches; edit it in console/claude-oc/.

    claude          joins this computer's session; each line typed is a
                    prompt; `exit` or Ctrl+D leaves (the session goes
                    on); Ctrl+C stops waiting
    claude stop     ends the session; the next `claude` makes a new one
    claude send <address start> <text>
                    mail for another computer, sent with this one's address
    claude mail     this computer's mailbox, kept on the PC

One computer is one Claude session, kept on the PC: the first `claude`
makes it, working in the directory it was run in, and only `claude stop`
ends it. It needs octerm running here and claude-oc.exe on the PC; the
zone they open shares package.loaded["claude-oc"] with this program. The
session is shared with claude-oc.exe's window: prompts typed there
show here as "PC>", with their answers, as they come. So the line being
typed is this program's own (term.read would block them out): letters,
Backspace, Delete, Left, Right, Home, End, Up and Down for earlier lines,
Enter, and `\` then Enter for a new row of the same prompt; a message that
comes in is printed above it, mail for this computer too. While Claude
works, the tools it uses show dimmed. One `claude` open per computer: a new
one takes the screen over. ]==]

local computer, event = require("computer"), require("event")
local shell, term = require("shell"), require("term")
local text, tty, unicode = require("text"), require("tty"), require("unicode")
local gpu = tty.gpu()

local BLUE, DIM, RED, WHITE = 0x60C0FF, 0x808080, 0xFF6060, 0xFFFFFF
local YELLOW = 0xFFD060
local K_ENTER, K_BACK, K_UP, K_DOWN = 0x1C, 0x0E, 0xC8, 0xD0
local K_LEFT, K_RIGHT, K_HOME, K_END, K_DELETE = 0xCB, 0xCD, 0xC7, 0xCF, 0xD3

local oc = package.loaded["claude-oc"]
if not oc or not oc.alive then
  io.stderr:write("claude: claude-oc.exe is not running on the PC (it needs"
    .. " octerm running here, and the relay on the PC)\n")
  return 1
end
local args = {...}

--! Prints `s` word-wrapped to the window, in colour `fg` when given.
local function say(s, fg)
  gpu.setForeground(fg or WHITE)
  local w = tty.getViewport()
  for para in (s .. "\n"):gmatch("([^\n]*)\n") do
    if para == "" then print() end
    for line in text.wrappedLines(para, w - 1, w - 1) do print(line) end
  end
  gpu.setForeground(WHITE)
end

--! Waits for the PC's answer to request `id`: {ok, text}, or nil after 10 s.
local function answer_to(id)
  local deadline = computer.uptime() + 10
  while computer.uptime() < deadline do
    local r = oc.reply(id)
    if r then return r end
    event.pull(1, "claude_oc")
  end
end

if args[1] == "stop" then
  print(oc.stop() and "claude: the session has ended; the next claude makes"
    .. " a new one" or "claude: this computer has no session")
  return
elseif args[1] == "send" and args[3] then
  local r = answer_to(oc.send(args[2], table.concat(args, " ", 3)))
  say("claude: " .. (r and r[2] or "no answer from claude-oc.exe"),
    r and r[1] and BLUE or RED)
  return r and r[1] and 0 or 1
elseif args[1] == "mail" then
  local r = answer_to(oc.mail())
  say(r and r[2] or "claude: no answer from claude-oc.exe", r and WHITE or RED)
  return
elseif args[1] then
  io.stderr:write("usage: claude                 this computer's session\n"
    .. "       claude stop            ends it\n"
    .. "       claude send <to> <text>  mail; <to>: the start of an address\n"
    .. "       claude mail            this computer's mailbox\n")
  return 1
end

-- THE LINE BEING TYPED ----------------------------------------------------

-- rows: the prompt's rows ended by `\` Enter; row: its open one; pos: the
-- cursor, in characters into it; back: how far up the history.
local rows, row, pos = {}, "", 0
local history, back = {}, 0
local typing = false                     -- the open row is on the screen

--! Returns what the open row is drawn after: "> " on a prompt's first row,
--! ". " on the rest.
local function mark() return #rows == 0 and "> " or ". " end

--! Draws a row: its mark, then the text.
local function draw_row(m, s)
  term.clearLine()
  gpu.setForeground(BLUE)
  io.write(m)
  gpu.setForeground(WHITE)
  io.write(s)
end

--! Draws the open row over the screen's current row, the part around the
--! cursor when it is wider than the window, with the cursor as a lit cell
--! where the next letter goes (OpenOS blinks its own only in term.read).
--! The prompt's earlier rows stay printed above it.
local function draw_line()
  local room = tty.getViewport() - 3
  local start = pos + 1 > room and pos - room + 2 or 1
  local at = unicode.sub(row, pos + 1, pos + 1)
  local bg = gpu.getBackground()
  draw_row(mark(), unicode.sub(row, start, pos))
  gpu.setBackground(WHITE)
  gpu.setForeground(bg)
  io.write(at == "" and " " or at)
  gpu.setBackground(bg)
  gpu.setForeground(WHITE)
  io.write(unicode.sub(row, pos + 2, start + room - 1))
  typing = true
end

--! Puts text in at the cursor.
local function insert(s)
  row = unicode.sub(row, 1, pos) .. s .. unicode.sub(row, pos + 1)
  pos = pos + unicode.len(s)
end

--! Brings back a prompt from the history: its earlier rows printed, its
--! last one open, with the cursor at its end.
local function recall(text)
  local all = {}
  for r in (text .. "\n"):gmatch("([^\n]*)\n") do all[#all + 1] = r end
  rows, row = {}, table.remove(all)
  for _, r in ipairs(all) do
    draw_row(mark(), r)
    print()
    rows[#rows + 1] = r
  end
  pos = unicode.len(row)
end

--! Prints a message above the line being typed, which is drawn again.
local function above(s, fg)
  if typing then term.clearLine() end
  say(s, fg)
  if typing then draw_line() end
end

--! Takes a key; returns the prompt when Enter ends it, or "quit" on Ctrl+D
--! with nothing typed. Letters go in at the cursor; Backspace and Delete
--! take out the character before and at it; Left, Right, Home and End
--! move it; Enter after a `\` starts a new row of the same prompt, as in
--! claude-oc.exe's window; Backspace at a row's start joins it to the one
--! above.
local function key(char, code)
  if code == K_ENTER and row:sub(-1) == "\\" then
    row = row:sub(1, -2)
    draw_row(mark(), row)
    print()
    rows[#rows + 1] = row
    row, pos = "", 0
  elseif code == K_ENTER then
    local all = table.concat(rows, "\n") .. (#rows > 0 and "\n" or "") .. row
    local done = all:gsub("[\n ]+$", "")
    if done ~= "" then table.insert(history, done) end
    draw_row(mark(), row)
    print()
    rows, row, pos, back = {}, "", 0, 0
    typing = false
    return done
  elseif code == K_BACK and pos > 0 then
    row = unicode.sub(row, 1, pos - 1) .. unicode.sub(row, pos + 1)
    pos = pos - 1
  elseif code == K_BACK and #rows > 0 then
    local up = table.remove(rows)
    row, pos = up .. row, unicode.len(up)
  elseif code == K_DELETE then
    row = unicode.sub(row, 1, pos) .. unicode.sub(row, pos + 2)
  elseif code == K_LEFT then
    pos = math.max(0, pos - 1)
  elseif code == K_RIGHT then
    pos = math.min(unicode.len(row), pos + 1)
  elseif code == K_HOME then
    pos = 0
  elseif code == K_END then
    pos = unicode.len(row)
  elseif code == K_UP or code == K_DOWN then
    back = math.max(0, math.min(#history, back + (code == K_UP and 1 or -1)))
    recall(back > 0 and history[#history + 1 - back] or "")
  elseif char == 4 and row == "" and #rows == 0 then
    return "quit"
  elseif char >= 32 and char ~= 127 then
    insert(unicode.char(char))
  end
  draw_line()
end

-- THE SESSION -------------------------------------------------------------

local me, made, dir = oc.start(shell.getWorkingDirectory())
if not me then
  io.stderr:write("claude: " .. made .. "\n")
  return 1
end
local waiting                            -- the id of the prompt sent

--! Shows what came back; returns false once claude must end.
local function take()
  for _, m in ipairs(oc.take(me)) do
    local kind, id = m[1], m[2]
    if kind == "note" then
      above("  " .. m[2], DIM)
    elseif kind == "pc_prompt" then
      above("PC> " .. m[2], BLUE)
    elseif kind == "mail" then
      above("mail from " .. m[2] .. ":\n" .. m[3], YELLOW)
    elseif kind == "answer" or kind == "no_answer" then
      if kind == "answer" then above(m[3])
      else above("claude: no answer: " .. m[3], RED) end
      if id == waiting then waiting = nil end
    elseif kind == "taken" then
      above("claude: another claude started here; this one ends", RED)
      return false
    elseif kind == "stopped" then
      above("claude: the session was ended (claude stop); this one ends", RED)
      return false
    elseif kind == "gone" then
      above("claude: claude-oc.exe went away; run claude again once it is "
        .. "back", RED)
      return false
    end
  end
  return true
end

say((made and "Claude: a new session for this computer, working in "
             or "Claude: back in this computer's session, working in ")
  .. dir .. ". Shared with claude-oc.exe's window on the PC. Type, then "
  .. "Enter; `exit` or Ctrl+D leaves, `claude stop` ends the session.", BLUE)
local kb = tty.keyboard()
while take() do
  if not waiting and not typing then draw_line() end
  local name, a, b, c = event.pullMultiple("key_down", "claude_oc",
                                           "interrupted", "clipboard")
  if name == "interrupted" and waiting then
    say("claude: stopped waiting; that answer will be shown when it comes",
      RED)
    waiting = nil
  elseif name == "interrupted" then
    row, pos = "", 0
    draw_line()
  elseif name == "clipboard" and a == kb and not waiting then
    insert(b:match("[^\r\n]*") or "")
    draw_line()
  elseif name == "key_down" and a == kb and not waiting then
    local done = key(b, c)
    if done == "quit" or done == "exit" then
      if typing then term.clearLine() end
      typing = false
      say("claude: the session goes on; `claude` comes back to it, `claude "
        .. "stop` ends it", DIM)
      break
    end
    if done and done ~= "" then
      local id, why = oc.ask(me, done)
      if not id then
        say("claude: " .. why, RED)
        break
      end
      waiting = id
    end
  end
end
if typing then term.clearLine() end
oc.quit(me)
