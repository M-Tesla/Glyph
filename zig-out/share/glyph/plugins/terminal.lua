-- mod-version:3
-- terminal.lua — Integrated terminal panel (Ctrl+J)
--
-- Windows: cmd.exe /Q with CREATE_NO_WINDOW (no_window=true) so that all I/O
--          goes through the pipes instead of a hidden console window.
-- Linux:   $SHELL -s (reads commands from piped stdin, no TTY needed).
--
-- Key insight: keypressed → keymap.on_key_pressed (NOT RootView.on_key_pressed)
--              textinput  → core.root_view:on_text_input (RootView override works)

local core     = require "core"
local common   = require "core.common"
local style    = require "core.style"
local config   = require "core.config"
local command  = require "core.command"
local keymap   = require "core.keymap"
local RootView = require "core.rootview"

config.plugins.terminal = common.merge({
  height    = 220,
  max_lines = 5000,
}, config.plugins.terminal)

local IS_WIN   = PLATFORM == "Windows"

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local visible   = false
local focused   = false
local lines     = {}        -- { text, kind }  kind: "out"|"err"|"in"|"sys"
local scroll_y  = 0         -- first visible line (0-based)
local input     = ""        -- current input text
local cursor    = 0         -- byte offset within input
local history   = {}
local hist_idx  = 0
local hist_draft = ""
local shell     = nil
local out_buf   = ""
local err_buf   = ""

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function push(text, kind)
  for s in (text .. "\n"):gmatch("([^\n]*)\n") do
    s = s:gsub("\r", "")
    -- strip common ANSI escape sequences so output is readable
    s = s:gsub("\27%[[%d;]*[A-Za-z]", "")
    s = s:gsub("\27%[%?%d+[hl]", "")
    if s ~= "" then
      table.insert(lines, { text = s, kind = kind or "out" })
    end
  end
  while #lines > config.plugins.terminal.max_lines do
    table.remove(lines, 1)
  end
  scroll_y = math.huge
  core.redraw = true
end

---------------------------------------------------------------------------
-- Shell management
---------------------------------------------------------------------------
local function shell_name()
  if IS_WIN then return "cmd.exe" end
  return os.getenv("SHELL") or "bash"
end

local function start_shell()
  if shell and shell:running() then return end
  out_buf = ""
  err_buf = ""

  local cmd
  if IS_WIN then
    -- /Q  suppress command echo
    -- /K  interactive mode: stays alive after errors (without /K, batch mode
    --     exits on first non-zero exit code — e.g. an unknown command)
    -- no_window=true → CREATE_NO_WINDOW so all I/O goes through the pipe
    cmd = { "cmd.exe", "/Q", "/K" }
  else
    local sh = os.getenv("SHELL") or "bash"
    -- --norc --noprofile: skip startup files for clean output
    -- -s: read commands from stdin
    cmd = { sh, "--norc", "--noprofile", "-s" }
  end

  -- project directory to cd into on startup
  local proj = core.project_directories
    and #core.project_directories > 0
    and core.project_directories[1].name or nil

  local ok, p = pcall(process.start, cmd, {
    stdout    = process.REDIRECT_PIPE,
    stderr    = process.REDIRECT_STDOUT,  -- merge stderr into stdout pipe
    stdin     = process.REDIRECT_PIPE,
    no_window = true,   -- CREATE_NO_WINDOW: pure pipe I/O, no hidden console
    cwd       = proj,   -- start in project directory
  })

  if not ok or not p then
    push("[Failed to start " .. shell_name() .. ": " .. tostring(p) .. "]", "sys")
    return
  end
  shell = p

  -- background reader — stdout (stderr merged in)
  core.add_thread(function()
    while shell and shell:running() do
      local chunk = shell:read_stdout(4096)
      if chunk and #chunk > 0 then
        out_buf = out_buf .. chunk
        -- process complete lines
        while true do
          local nl = out_buf:find("\n")
          if not nl then break end
          local ln = out_buf:sub(1, nl - 1)
          out_buf  = out_buf:sub(nl + 1)
          push(ln, "out")
        end
      else
        coroutine.yield()
      end
    end
    -- drain any remaining partial line
    if out_buf ~= "" then push(out_buf, "out"); out_buf = "" end
    if shell then
      push("[Shell exited — press Ctrl+J to restart]", "sys")
      shell = nil
      core.redraw = true
    end
  end)

  push("[Terminal ready — " .. shell_name() .. (proj and ("  " .. proj) or "") .. "]", "sys")
end

local function send_cmd(text)
  if not shell or not shell:running() then
    start_shell()
    if not shell then return end
  end
  if text ~= "" then
    if not history[#history] or history[#history] ~= text then
      table.insert(history, text)
      if #history > 200 then table.remove(history, 1) end
    end
  end
  hist_idx = 0
  push("$ " .. text, "in")
  if IS_WIN then
    shell:write(text .. "\r\n")
  else
    shell:write(text .. "\n")
  end
end

---------------------------------------------------------------------------
-- Draw
---------------------------------------------------------------------------
local CLOSE_W = 14   -- width reserved for [×] button

local function draw_panel(px, py, pw, ph)
  local s     = SCALE
  local H_HDR = math.floor(22 * s)
  local H_IN  = math.floor(28 * s)
  local PAD   = math.floor(6 * s)
  local f     = style.code_font or style.font
  local lh    = f:get_height() + math.floor(3 * s)

  -- Background + top border
  renderer.draw_rect(px, py, pw, 1, style.divider)
  renderer.draw_rect(px, py + 1, pw, ph - 1, style.background)

  -- ── Header bar ──────────────────────────────────────────────────────────
  local hbg = style.background2 or style.background
  renderer.draw_rect(px, py + 1, pw, H_HDR, hbg)

  -- Shell label
  local lbl = "TERMINAL  " .. shell_name()
  renderer.draw_text(f, lbl,
    px + PAD, py + 1 + math.floor((H_HDR - f:get_height()) / 2), style.text)

  -- Running indicator
  local indicator = (shell and shell:running()) and "●" or "○"
  local ind_col   = (shell and shell:running())
    and (style.accent or { 80, 200, 80, 255 })
    or  style.dim
  local ind_w = f:get_width(indicator)
  renderer.draw_text(f, indicator,
    px + pw - PAD - CLOSE_W - 8 - ind_w,
    py + 1 + math.floor((H_HDR - f:get_height()) / 2),
    ind_col)

  -- Close [×]
  local cx_btn = px + pw - PAD - f:get_width("×")
  renderer.draw_text(f, "×",
    cx_btn, py + 1 + math.floor((H_HDR - f:get_height()) / 2), style.dim)

  -- ── Input bar (bottom) ──────────────────────────────────────────────────
  local iy = py + ph - H_IN
  renderer.draw_rect(px, iy, pw, 1, style.divider)
  renderer.draw_rect(px, iy + 1, pw, H_IN - 1, hbg)

  local prompt_col = focused
    and (style.accent or style.keyword or style.text)
    or  style.dim
  local prompt  = "$ "
  local prompt_w = f:get_width(prompt)
  local ty      = iy + math.floor((H_IN - f:get_height()) / 2)
  renderer.draw_text(f, prompt, px + PAD, ty, prompt_col)
  renderer.draw_text(f, input,  px + PAD + prompt_w, ty, style.text)

  -- Cursor
  if focused then
    local caret_x = px + PAD + prompt_w + f:get_width(input:sub(1, cursor))
    renderer.draw_rect(caret_x, iy + math.floor(4 * s),
      math.floor(2 * s), f:get_height(), style.caret or style.text)
  end

  -- ── Output area ─────────────────────────────────────────────────────────
  local oy    = py + H_HDR + 1
  local oh    = ph - H_HDR - H_IN - 1
  local n_vis = math.max(1, math.floor(oh / lh))
  local max_s = math.max(0, #lines - n_vis)
  if scroll_y == math.huge then scroll_y = max_s end
  scroll_y = math.max(0, math.min(math.floor(scroll_y), max_s))

  -- clip output area
  renderer.draw_rect(px, oy, pw, oh, style.background)

  for i = scroll_y + 1, math.min(#lines, scroll_y + n_vis) do
    local ln  = lines[i]
    local ly  = oy + (i - scroll_y - 1) * lh + math.floor(PAD / 2)
    local col = ln.kind == "in"  and (style.accent or style.keyword or style.text)
             or ln.kind == "sys" and style.dim
             or style.text
    renderer.draw_text(f, ln.text, px + PAD, ly, col)
  end

  -- Scrollbar
  if #lines > n_vis then
    local th  = math.max(20, math.floor(oh * n_vis / #lines))
    local ty2 = oy + math.floor((scroll_y / math.max(1, max_s)) * (oh - th))
    renderer.draw_rect(px + pw - 4, ty2, 3, th, style.scrollbar or style.dim)
  end
end

---------------------------------------------------------------------------
-- RootView hooks
---------------------------------------------------------------------------

-- Draw: shrink editor area, draw panel below
local rv_draw_orig = RootView.draw
function RootView:draw()
  local ph = visible and config.plugins.terminal.height or 0
  if ph > 0 then self.size.y = self.size.y - ph end
  rv_draw_orig(self)
  if ph > 0 then
    self.size.y = self.size.y + ph
    draw_panel(0, self.size.y - ph, self.size.x, ph)
  end
end

-- Mouse wheel: scroll inside panel
local rv_wheel_orig = RootView.on_mouse_wheel
function RootView:on_mouse_wheel(x, y, dx, dy)
  if visible and y >= self.size.y - config.plugins.terminal.height then
    scroll_y = math.max(0, scroll_y - dy * 3)
    core.redraw = true
    return true
  end
  return rv_wheel_orig(self, x, y, dx, dy)
end

-- Mouse press: focus / close
local rv_mouse_orig = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  if visible then
    local ph    = config.plugins.terminal.height
    local f     = style.code_font or style.font
    local PAD   = math.floor(6 * SCALE)
    local H_HDR = math.floor(22 * SCALE)
    if y >= self.size.y - ph then
      local cx_btn = self.size.x - PAD - f:get_width("×")
      if y <= self.size.y - ph + H_HDR + 1 and x >= cx_btn then
        command.perform("terminal:toggle")
      else
        focused = true
        core.redraw = true
      end
      return true
    else
      if focused then
        focused = false
        core.redraw = true
      end
    end
  end
  return rv_mouse_orig(self, button, x, y, clicks)
end

-- Text input: intercept when terminal focused
local rv_text_orig = RootView.on_text_input
function RootView:on_text_input(text)
  if visible and focused then
    input  = input:sub(1, cursor) .. text .. input:sub(cursor + 1)
    cursor = cursor + #text
    core.redraw = true
    return
  end
  rv_text_orig(self, text)
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
local function term_focused() return visible and focused end

command.add(term_focused, {
  ["terminal:backspace"] = function()
    if cursor == 0 then return end
    local p = cursor
    repeat p = p - 1
    until p == 0 or (input:byte(p) or 0) & 0xC0 ~= 0x80
    input  = input:sub(1, p - 1) .. input:sub(cursor + 1)
    cursor = p - 1
    core.redraw = true
  end,

  ["terminal:delete"] = function()
    if cursor >= #input then return end
    local p = cursor + 1
    repeat p = p + 1
    until p > #input or (input:byte(p) or 0) & 0xC0 ~= 0x80
    input = input:sub(1, cursor) .. input:sub(p)
    core.redraw = true
  end,

  ["terminal:send"] = function()
    local cmd = input
    input  = ""
    cursor = 0
    send_cmd(cmd)
    core.redraw = true
  end,

  ["terminal:history-prev"] = function()
    if #history == 0 then return end
    if hist_idx == 0 then hist_draft = input end
    hist_idx = math.min(hist_idx + 1, #history)
    input    = history[#history - hist_idx + 1]
    cursor   = #input
    core.redraw = true
  end,

  ["terminal:history-next"] = function()
    if hist_idx == 0 then return end
    hist_idx = hist_idx - 1
    input    = hist_idx == 0 and hist_draft or history[#history - hist_idx + 1]
    cursor   = #input
    core.redraw = true
  end,

  ["terminal:cursor-left"] = function()
    if cursor == 0 then return end
    cursor = cursor - 1
    while cursor > 0 and (input:byte(cursor + 1) or 0) & 0xC0 == 0x80 do
      cursor = cursor - 1
    end
    core.redraw = true
  end,

  ["terminal:cursor-right"] = function()
    if cursor >= #input then return end
    cursor = cursor + 1
    while cursor < #input and (input:byte(cursor + 1) or 0) & 0xC0 == 0x80 do
      cursor = cursor + 1
    end
    core.redraw = true
  end,

  ["terminal:home"] = function()
    cursor = 0; core.redraw = true
  end,

  ["terminal:end"] = function()
    cursor = #input; core.redraw = true
  end,

  ["terminal:unfocus"] = function()
    focused = false; core.redraw = true
  end,

  ["terminal:interrupt"] = function()
    if shell and shell:running() then
      -- Send Ctrl+C byte; on Linux this signals the foreground process
      shell:write("\x03")
      push("^C", "sys")
      core.redraw = true
    end
  end,

  ["terminal:clear"] = function()
    lines    = {}
    scroll_y = 0
    core.redraw = true
  end,
})

command.add(nil, {
  ["terminal:toggle"] = function()
    visible = not visible
    if visible then
      focused = true
      if not shell or not shell:running() then start_shell() end
    else
      focused = false
    end
    core.redraw = true
  end,
})

---------------------------------------------------------------------------
-- Keybindings
---------------------------------------------------------------------------
keymap.add {
  ["ctrl+j"]       = "terminal:toggle",
  ["ctrl+shift+k"] = "terminal:clear",
  ["ctrl+l"]       = "terminal:clear",

  ["backspace"]    = "terminal:backspace",
  ["delete"]       = "terminal:delete",
  ["return"]       = "terminal:send",
  ["kpenter"]      = "terminal:send",
  ["up"]           = "terminal:history-prev",
  ["down"]         = "terminal:history-next",
  ["left"]         = "terminal:cursor-left",
  ["right"]        = "terminal:cursor-right",
  ["home"]         = "terminal:home",
  ["end"]          = "terminal:end",
  ["escape"]       = "terminal:unfocus",
  ["ctrl+c"]       = "terminal:interrupt",
}

return {}
