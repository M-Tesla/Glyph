-- mod-version:3
-- selection_actions.lua — Floating action buttons when text is selected in a DocView.
-- Shows: [Explain] [Fix] [Refactor] [→ Chat] near the end of the selection.
-- Clicking opens AI Chat (aichat.lua) with the selected code pre-loaded.

local core    = require "core"
local common  = require "core.common"
local config  = require "core.config"
local style   = require "core.style"
local DocView = require "core.docview"
local renderer = require "renderer"

config.plugins.selection_actions = common.merge({
  enabled = true,
}, config.plugins.selection_actions)

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------
local ACTIONS = {
  { label = "Explain",  prefix = "Explain the following code in plain terms:",  auto = true  },
  { label = "Fix",      prefix = "Fix any bugs in the following code:",          auto = false },
  { label = "Refactor", prefix = "Refactor the following code for clarity:",     auto = false },
  { label = "→ Chat",  prefix = "",                                              auto = false },
}

---------------------------------------------------------------------------
-- Per-view state (keyed by view object)
---------------------------------------------------------------------------
local state = {
  rects   = {},   -- { action_idx, x, y, w, h }
  hovered = nil,  -- action index (1-based) or nil
  view    = nil,  -- the DocView that owns the current popup
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function get_sel_text(doc)
  -- doc:get_selection_text() is available in Glyph
  local ok, txt = pcall(function() return doc:get_selection_text(8192) end)
  if ok and txt and txt ~= "" then return txt end
  -- Fallback: manual extraction
  local l1, c1, l2, c2 = doc:get_selection(true)
  if l1 == l2 and c1 == c2 then return nil end
  local lines = {}
  for i = l1, l2 do
    local line = doc.lines[i] or ""
    if i == l1 and i == l2 then
      table.insert(lines, line:sub(c1, c2 - 1))
    elseif i == l1 then
      table.insert(lines, line:sub(c1))
    elseif i == l2 then
      table.insert(lines, line:sub(1, c2 - 1))
    else
      table.insert(lines, line)
    end
  end
  return table.concat(lines)
end

local function has_selection(doc)
  local l1, c1, l2, c2 = doc:get_selection(true)
  return not (l1 == l2 and c1 == c2)
end

---------------------------------------------------------------------------
-- Draw: wrap DocView:draw to paint the popup on top
---------------------------------------------------------------------------
local orig_draw = DocView.draw
function DocView:draw()
  orig_draw(self)

  if not config.plugins.selection_actions.enabled then return end
  if self ~= core.active_view then return end
  local doc = self.doc
  if not doc or not has_selection(doc) then
    state.rects   = {}
    state.hovered = nil
    return
  end

  local font = style.font
  local pad  = math.floor(style.padding.x * 0.6)
  local bh   = font:get_height() + pad * 2

  -- Position: below the last selected line, right-aligned within the view
  local l1, c1, l2, c2 = doc:get_selection(true)  -- sorted
  local _, sel_end_y  = self:get_line_screen_position(l2)
  local lh = self:get_line_height()
  local by = sel_end_y + lh + 2  -- one line below the last selected line

  local view_bottom = self.position.y + self.size.y - style.padding.y
  local view_top    = self.position.y + style.padding.y

  -- If the popup would go off the bottom, put it above the first selected line
  if by + bh > view_bottom then
    local _, sel_start_y = self:get_line_screen_position(l1)
    by = sel_start_y - bh - 2
  end

  -- If still off-screen (too high), bail
  if by + bh < view_top or by > view_bottom then
    state.rects   = {}
    state.hovered = nil
    return
  end

  state.view  = self
  state.rects = {}

  local accent = style.accent or style.caret or style.text
  -- Draw buttons right-to-left from the right edge of the view
  local bx = self.position.x + self.size.x - style.padding.x
  for i = #ACTIONS, 1, -1 do
    local a  = ACTIONS[i]
    local bw = font:get_width(a.label) + pad * 2
    bx = bx - bw - 2

    local is_hov = (state.hovered == i)
    local bg = is_hov
      and { accent[1], accent[2], accent[3], 60 }
      or  { (style.background2 or style.background)[1],
            (style.background2 or style.background)[2],
            (style.background2 or style.background)[3], 220 }

    renderer.draw_rect(bx, by, bw, bh, bg)
    -- thin border
    renderer.draw_rect(bx,          by,      bw, 1, style.dim)
    renderer.draw_rect(bx,          by + bh, bw, 1, style.dim)
    renderer.draw_rect(bx,          by,      1, bh, style.dim)
    renderer.draw_rect(bx + bw - 1, by,      1, bh, style.dim)

    renderer.draw_text(font, a.label, bx + pad, by + pad,
      is_hov and accent or style.text)

    -- Store rect in forward order (so index i maps to ACTIONS[i])
    table.insert(state.rects, { idx = i, x = bx, y = by, w = bw, h = bh })
  end
end

---------------------------------------------------------------------------
-- Mouse press: intercept clicks on the buttons
---------------------------------------------------------------------------
local orig_press = DocView.on_mouse_pressed
function DocView:on_mouse_pressed(button, x, y, clicks)
  if config.plugins.selection_actions.enabled
    and self == state.view
    and #state.rects > 0
  then
    for _, r in ipairs(state.rects) do
      if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
        local action = ACTIONS[r.idx]
        local sel    = get_sel_text(self.doc) or ""
        if _G.glyph_ai_send then
          _G.glyph_ai_send(action.prefix, sel, action.auto)
        else
          core.log("selection_actions: aichat plugin not loaded")
        end
        state.rects   = {}
        state.hovered = nil
        core.redraw   = true
        return true
      end
    end
  end
  return orig_press(self, button, x, y, clicks)
end

---------------------------------------------------------------------------
-- Mouse move: update hover state
---------------------------------------------------------------------------
local orig_moved = DocView.on_mouse_moved
function DocView:on_mouse_moved(mx, my, ...)
  if config.plugins.selection_actions.enabled
    and self == state.view
    and #state.rects > 0
  then
    local prev = state.hovered
    state.hovered = nil
    for _, r in ipairs(state.rects) do
      if mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h then
        state.hovered = r.idx
        break
      end
    end
    if state.hovered ~= prev then core.redraw = true end
  end
  return orig_moved(self, mx, my, ...)
end
