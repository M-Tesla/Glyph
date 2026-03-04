-- mod-version:3
-- tutorial.lua — First-launch guided tour for Glyph
-- Shows a modal overlay on first run; reopenable via Command Palette.

local core     = require "core"
local command  = require "core.command"
local keymap   = require "core.keymap"
local style    = require "core.style"
local RootView = require "core.rootview"

-------------------------------------------------------------------------------
-- Steps
-------------------------------------------------------------------------------
local STEPS = {
  {
    title = "Welcome to Glyph",
    body  = {
      "Glyph is a business-driven IDE powered by a native",
      "Zig backend and Claude AI. Built for teams that care",
      "about architecture, domain knowledge, and code quality.",
      "",
      "This tour covers the key features — takes ~2 minutes.",
      "",
      "  ←  /  →   or   Prev / Next   to navigate",
      "  Escape   or   Skip   to dismiss at any time",
    },
  },
  {
    title = "Open a Project",
    key   = "Ctrl+Shift+O",
    body  = {
      "Open any folder as your active project. Glyph indexes",
      "all files so you can navigate instantly.",
      "",
      "  Ctrl+P          Quick file open (fuzzy search)",
      "  Ctrl+Shift+O    Open folder as project",
      "  Ctrl+W          Close current file",
      "  Ctrl+Tab        Switch between open files",
      "",
      "Tip: add build artifacts to  config.ignore_files  in",
      "your user config to keep the index fast.",
    },
  },
  {
    title = "Connect Claude",
    key   = "Ctrl+Shift+A",
    body  = {
      "Glyph uses Claude AI. To connect, you need either:",
      "  • Claude Pro subscription  (claude.ai)",
      "  • Anthropic API key",
      "",
      "1. Open AI Chat with  Ctrl+Shift+A",
      "2. Click  'Login with Claude.ai'  in the panel",
      "3. A terminal opens — follow the login instructions",
      "",
      "Requires the VS Code Claude extension installed,",
      "or  claude  available in your PATH.",
    },
  },
  {
    title = "AI Chat",
    key   = "Ctrl+Shift+A",
    body  = {
      "Once connected, your AI co-pilot lives in the right",
      "panel. Ask anything: architecture, code review, domain.",
      "",
      "Type  /  in the input to see slash commands:",
      "  /explain    Explain selected code or visible context",
      "  /review     Review git diff or current file",
      "  /adr        Create an Architecture Decision Record",
      "  /eks-setup  Scaffold the .glyph/ knowledge folder",
      "",
      "Mention files with  @filename  to inject their content.",
    },
  },
  {
    title = "Inline AI Suggestions",
    body  = {
      "Ghost-text completions appear as you type code.",
      "",
      "  Tab      Accept the suggestion",
      "  Escape   Dismiss",
      "",
      "Suggestions are context-aware: they read your open file,",
      "cursor position, and the project language.",
      "",
      "Auto-triggers after a short idle pause. You can also",
      "trigger manually via the Command Palette.",
    },
  },
  {
    title = "Language Server (LSP)",
    body  = {
      "Full LSP support for any language server",
      "(zls, clangd, pyright, typescript-language-server...).",
      "",
      "  Ctrl+Space          Completions",
      "  Ctrl+K              Hover documentation",
      "  F12                 Go to definition",
      "  F2                  Rename symbol",
      "  Ctrl+.              Code actions",
      "  Shift+F12           Find references",
      "  Ctrl+Shift+Space    Signature help",
    },
  },
  {
    title = "Integrated Terminal",
    key   = "Ctrl+J",
    body  = {
      "A persistent shell at the bottom of the editor.",
      "Windows uses  cmd.exe,  Linux/macOS use  $SHELL.",
      "",
      "  Ctrl+J    Toggle the terminal panel",
      "  ↑ / ↓    Navigate command history",
      "  Ctrl+C    Send interrupt signal",
      "  Ctrl+L    Clear the screen",
      "",
      "The shell session stays alive while the panel is hidden.",
      "Your working directory and environment persist.",
    },
  },
  {
    title = "Git Gutter & Branch",
    body  = {
      "Git change indicators appear in the line gutter",
      "automatically whenever you save a file.",
      "",
      "  Green bar    New lines added",
      "  Yellow bar   Modified lines",
      "  Red bar      Deleted lines",
      "",
      "The current branch name is shown on the left side",
      "of the status bar at the bottom of the window.",
    },
  },
  {
    title = "Selection Actions",
    body  = {
      "Select any code in the editor. Floating action buttons",
      "appear near your selection automatically:",
      "",
      "  Explain    AI explanation of the selected code",
      "  Fix        AI-suggested bug fix",
      "  Refactor   AI refactoring suggestions",
      "  → Chat     Send to AI Chat with full context",
      "",
      "Buttons appear below the selection and shift above",
      "it when near the bottom of the screen.",
    },
  },
  {
    title = "Enterprise Knowledge System",
    body  = {
      "Build a living knowledge base for your project inside",
      "the  Knowledge  and  Decisions  tabs of AI Chat.",
      "",
      "Run  /eks-setup  to create the  .glyph/  folder:",
      "  knowledge/   Domain docs, architecture, standards",
      "  decisions/   Architecture Decision Records (ADRs)",
      "",
      "ADRs track *why* key decisions were made.",
      "Run  /adr <title>  to create a new one.",
      "The AI reads this context automatically on every query.",
    },
  },
  {
    title = "You're all set!",
    body  = {
      "Press  Ctrl+Shift+P  to open the Command Palette",
      "and discover every available action in Glyph.",
      "",
      "A  WELCOME.md  file is open in your editor with",
      "the complete feature reference — keep it handy.",
      "",
      "This tour is available anytime:",
      "  Command Palette  →  Show Tutorial",
      "",
      "Welcome to Glyph.",
    },
  },
}

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local visible  = false
local step     = 1
local mouse_x  = 0
local mouse_y  = 0

local btn_next = { x=0, y=0, w=0, h=0 }
local btn_prev = { x=0, y=0, w=0, h=0 }
local btn_skip = { x=0, y=0, w=0, h=0 }

-------------------------------------------------------------------------------
-- Persistence
-------------------------------------------------------------------------------
local function done_path()
  return USERDIR .. PATHSEP .. "tutorial_done"
end

local function mark_done()
  local f = io.open(done_path(), "w")
  if f then f:write("1"); f:close() end
end

local function already_done()
  return system.get_file_info(done_path()) ~= nil
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local function in_rect(r, x, y)
  return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

local function finish()
  visible = false
  mark_done()
  core.redraw = true
end

-------------------------------------------------------------------------------
-- Drawing
-------------------------------------------------------------------------------
local PAD    = 28
local BTN_W  = 80
local BTN_H  = 30
local DOT_W  = 10
local DOT_H  = 10
local DOT_GAP = 12

local function accent_color()
  return style.accent or style.caret or { 96, 175, 255, 255 }
end

local function draw_btn(label, r, hovered)
  local bg = hovered
    and (style.selection or { 50, 100, 200, 200 })
    or  (style.background3 or style.scrollbar or { 40, 40, 40, 220 })
  renderer.draw_rect(r.x, r.y, r.w, r.h, bg)
  -- border
  renderer.draw_rect(r.x,           r.y,           r.w, 1, style.divider)
  renderer.draw_rect(r.x,           r.y + r.h - 1, r.w, 1, style.divider)
  renderer.draw_rect(r.x,           r.y,           1, r.h, style.divider)
  renderer.draw_rect(r.x + r.w - 1, r.y,           1, r.h, style.divider)
  local fw = style.font:get_width(label)
  local fh = style.font:get_height()
  local tx = r.x + math.floor((r.w - fw) / 2)
  local ty = r.y + math.floor((r.h - fh) / 2)
  renderer.draw_text(style.font, label, tx, ty, hovered and style.text or style.dim)
end

local function draw_overlay()
  local sw = core.root_view.size.x
  local sh = core.root_view.size.y

  -- Backdrop
  renderer.draw_rect(0, 0, sw, sh, { 0, 0, 0, 190 })

  local s     = STEPS[step]
  local font  = style.font
  local bfont = style.big_font
  local lh    = font:get_height() + 4

  -- Card sizing
  local card_w  = math.min(520, sw - 48)
  local inner_w = card_w - PAD * 2
  local title_h = bfont:get_height() + 8
  local body_h  = #s.body * lh
  local dots_h  = DOT_H + 14
  local btns_h  = BTN_H + 12
  local card_h  = PAD + title_h + 6 + 1 + 10 + body_h + PAD + dots_h + btns_h + PAD

  local cx = math.floor((sw - card_w) / 2)
  local cy = math.floor((sh - card_h) / 2)

  -- Card shadow
  renderer.draw_rect(cx + 4, cy + 4, card_w, card_h, { 0, 0, 0, 120 })
  -- Card border
  renderer.draw_rect(cx - 1, cy - 1, card_w + 2, card_h + 2, style.divider)
  -- Card background
  renderer.draw_rect(cx, cy, card_w, card_h, style.background)

  -- Accent bar on left edge
  renderer.draw_rect(cx, cy, 3, card_h, accent_color())

  -- Title
  local ty = cy + PAD
  renderer.draw_text(bfont, s.title, cx + PAD + 3, ty, accent_color())

  -- Shortcut badge (right-aligned, vertically centered with title)
  if s.key then
    local bfh     = bfont:get_height()
    local kpad    = 7
    local kw      = font:get_width(s.key) + kpad * 2
    local kh      = font:get_height() + 6
    local kx      = cx + card_w - PAD - kw
    local ky      = ty + math.floor((bfh - kh) / 2)
    local bg      = style.background3 or style.line_number or { 50, 50, 60, 255 }
    renderer.draw_rect(kx, ky, kw, kh, bg)
    renderer.draw_rect(kx,          ky,          kw, 1, accent_color())
    renderer.draw_rect(kx,          ky + kh - 1, kw, 1, accent_color())
    renderer.draw_rect(kx,          ky,          1, kh, accent_color())
    renderer.draw_rect(kx + kw - 1, ky,          1, kh, accent_color())
    renderer.draw_text(font, s.key, kx + kpad, ky + 3, style.text)
  end

  ty = ty + title_h + 6

  -- Divider
  renderer.draw_rect(cx + PAD, ty, inner_w, 1, style.divider)
  ty = ty + 10

  -- Body lines
  for _, line in ipairs(s.body) do
    if line ~= "" then
      -- Lines starting with spaces are "shortcuts" — highlight differently
      local col = (line:sub(1,2) == "  ") and style.text or style.dim
      renderer.draw_text(font, line, cx + PAD + 3, ty, col)
    end
    ty = ty + lh
  end

  -- Step dots
  local dot_total = #STEPS * DOT_W + (#STEPS - 1) * DOT_GAP
  local dx = cx + math.floor((card_w - dot_total) / 2)
  local dot_y = cy + card_h - PAD - btns_h - dots_h + 2
  for i = 1, #STEPS do
    local col = (i == step) and accent_color() or style.divider
    renderer.draw_rect(dx, dot_y, DOT_W, DOT_H, col)
    dx = dx + DOT_W + DOT_GAP
  end

  -- Step counter text  e.g. "3 / 10"
  local counter = step .. " / " .. #STEPS
  local cw = font:get_width(counter)
  renderer.draw_text(font, counter,
    cx + card_w - PAD - cw,
    dot_y + 1,
    style.dim)

  -- Buttons
  local brow_y = cy + card_h - PAD - BTN_H

  -- [Skip] — left
  btn_skip = { x = cx + PAD, y = brow_y, w = BTN_W, h = BTN_H }
  draw_btn("Skip", btn_skip, in_rect(btn_skip, mouse_x, mouse_y))

  -- [Next/Done] — right
  local is_last   = (step == #STEPS)
  local next_lbl  = is_last and "Done ✓" or "Next ›"
  btn_next = { x = cx + card_w - PAD - BTN_W, y = brow_y, w = BTN_W, h = BTN_H }
  draw_btn(next_lbl, btn_next, in_rect(btn_next, mouse_x, mouse_y))

  -- [Prev] — second from right
  btn_prev = { x = btn_next.x - 8 - BTN_W, y = brow_y, w = BTN_W, h = BTN_H }
  if step > 1 then
    draw_btn("‹ Prev", btn_prev, in_rect(btn_prev, mouse_x, mouse_y))
  end

  -- Keyboard hint at very bottom
  local hint = "← → navigate   ·   Escape skip"
  local hw = font:get_width(hint)
  renderer.draw_text(font, hint,
    cx + math.floor((card_w - hw) / 2),
    brow_y + BTN_H + 6,
    style.dim)
end

-------------------------------------------------------------------------------
-- RootView hooks
-------------------------------------------------------------------------------
local rv_draw_orig = RootView.draw
function RootView:draw()
  rv_draw_orig(self)
  if visible then draw_overlay() end
end

local rv_moved_orig = RootView.on_mouse_moved
function RootView:on_mouse_moved(x, y, ...)
  mouse_x, mouse_y = x, y
  if visible then
    core.redraw = true
    return
  end
  rv_moved_orig(self, x, y, ...)
end

local rv_press_orig = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  if not visible then return rv_press_orig(self, button, x, y, clicks) end
  if in_rect(btn_next, x, y) then
    if step < #STEPS then step = step + 1 else finish() end
    core.redraw = true
  elseif in_rect(btn_prev, x, y) and step > 1 then
    step = step - 1
    core.redraw = true
  elseif in_rect(btn_skip, x, y) then
    finish()
  end
  return true
end

-------------------------------------------------------------------------------
-- Commands & keymap
-------------------------------------------------------------------------------
command.add(function() return visible end, {
  ["tutorial:next"] = function()
    if step < #STEPS then step = step + 1 else finish() end
    core.redraw = true
  end,
  ["tutorial:prev"] = function()
    if step > 1 then step = step - 1 end
    core.redraw = true
  end,
  ["tutorial:skip"] = function()
    finish()
  end,
})

command.add(nil, {
  ["tutorial:show"] = function()
    step    = 1
    visible = true
    core.redraw = true
  end,
})

keymap.add {
  ["return"] = "tutorial:next",
  ["right"]  = "tutorial:next",
  ["left"]   = "tutorial:prev",
  ["escape"] = "tutorial:skip",
}

-------------------------------------------------------------------------------
-- Auto-start on first launch
-------------------------------------------------------------------------------
core.add_thread(function()
  coroutine.yield()
  coroutine.yield()
  if already_done() then return end

  -- Open WELCOME.md as the first tab
  local welcome = DATADIR .. PATHSEP .. "WELCOME.md"
  if system.get_file_info(welcome) then
    local ok, doc = pcall(core.open_doc, welcome)
    if ok then
      core.root_view:open_doc(doc)
    end
  end

  -- Show the tutorial overlay
  command.perform "tutorial:show"
end)
