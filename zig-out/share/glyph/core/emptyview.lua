local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local keymap = require "core.keymap"
local View = require "core.view"

---@class core.emptyview : core.view
---@field super core.view
local EmptyView = View:extend()

function EmptyView:__tostring() return "EmptyView" end

function EmptyView:new()
  EmptyView.super.new(self)
  self.scrollable = true
  self.hovered_button = nil
  self.hovered_recent = nil
  self.buttons = {}
  self.recent_rects = {}
end

function EmptyView:get_name() return "Get Started" end
function EmptyView:get_filename() return "" end

function EmptyView:get_scrollable_size()
  return self.last_content_height or self.size.y
end


local function get_recent_projects()
  local r = {}
  if core.recent_projects then
    for i, p in ipairs(core.recent_projects) do
      if i > 6 then break end
      r[#r+1] = { name = p:match("[/\\]([^/\\]+)$") or p, path = p }
    end
  end
  return r
end


function EmptyView:draw()
  self:draw_background(style.background)

  local ox, oy = self:get_content_offset()
  local font = style.font
  local big_font = style.big_font
  local pad = style.padding.x
  local line_h = font:get_height() + style.padding.y
  local cx = ox + self.size.x / 2

  self.buttons = {}
  self.recent_rects = {}

  -- Title
  local title_y = oy + math.floor(pad * 2)
  local title = "Glyph"
  local tw = big_font:get_width(title)
  renderer.draw_text(big_font, title, cx - tw / 2, title_y, style.dim)

  local ver = VERSION
  local vw = font:get_width(ver)
  local ver_y = title_y + big_font:get_height() + 2
  renderer.draw_text(font, ver, cx - vw / 2, ver_y,
    { style.dim[1], style.dim[2], style.dim[3], 100 })

  local y = ver_y + line_h + pad

  -- Buttons
  local btn_h = math.floor(line_h + style.padding.y)
  local btn_defs = {
    { label = "Open Folder",  cmd = "core:open-project-folder" },
    { label = "Open File",    cmd = "core:find-file" },
    { label = "Commands",     cmd = "core:find-command" },
  }
  local total_w, bws = 0, {}
  for _, b in ipairs(btn_defs) do
    local w = font:get_width(b.label) + pad * 2
    bws[#bws+1] = w
    total_w = total_w + w + pad
  end
  total_w = total_w - pad
  local bx = cx - total_w / 2
  for i, b in ipairs(btn_defs) do
    local w = bws[i]
    local hov = (self.hovered_button == i)
    -- Button background
    local bg = hov and (style.line_highlight or style.line) or style.background2
    renderer.draw_rect(bx, y, w, btn_h, bg)
    -- Button text
    local tc = hov and style.text or style.dim
    local tx = bx + (w - font:get_width(b.label)) / 2
    local ty = y + (btn_h - font:get_height()) / 2
    renderer.draw_text(font, b.label, tx, ty, tc)
    self.buttons[#self.buttons+1] = { x = bx, y = y, w = w, h = btn_h, cmd = b.cmd }
    bx = bx + w + pad
  end
  y = y + btn_h + math.floor(style.padding.y / 2)

  -- Keyboard hints
  local hints = {}
  for _, b in ipairs(btn_defs) do
    local k = keymap.get_binding(b.cmd)
    if k then hints[#hints+1] = k .. " " .. b.label:lower() end
  end
  local ht = table.concat(hints, "    ")
  renderer.draw_text(font, ht, cx - font:get_width(ht) / 2, y,
    { style.dim[1], style.dim[2], style.dim[3], 80 })
  y = y + line_h * 1.5

  -- Recent Projects
  local recents = get_recent_projects()
  if #recents > 0 then
    local hdr = "Recent Projects"
    renderer.draw_text(font, hdr, cx - font:get_width(hdr) / 2, y, style.dim)
    y = y + line_h
    for i, proj in ipairs(recents) do
      local ih = (self.hovered_recent == i)
      local nc = ih and (style.accent or style.caret or style.text) or style.text
      local pc = ih and style.text or style.dim
      local ps = common.home_encode(proj.path)
      local nw = font:get_width(proj.name)
      local pw = font:get_width(ps)
      local rw = nw + pad + pw
      local rx = cx - rw / 2
      renderer.draw_text(font, proj.name, rx, y, nc)
      renderer.draw_text(font, ps, rx + nw + pad, y, pc)
      self.recent_rects[#self.recent_rects+1] = {
        x = rx, y = y, w = rw, h = font:get_height(), path = proj.path, index = i
      }
      y = y + line_h
    end
  end

  self.last_content_height = (y + pad) - oy
  self:draw_scrollbar()
end


function EmptyView:on_mouse_pressed(button, x, y, clicks)
  local caught = EmptyView.super.on_mouse_pressed(self, button, x, y, clicks)
  if caught then return caught end

  for _, btn in ipairs(self.buttons) do
    if x >= btn.x and x < btn.x + btn.w and y >= btn.y and y < btn.y + btn.h then
      command.perform(btn.cmd)
      return true
    end
  end
  for _, rect in ipairs(self.recent_rects) do
    if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
      core.open_folder_project(rect.path)
      return true
    end
  end
end


function EmptyView:on_mouse_moved(x, y, dx, dy)
  EmptyView.super.on_mouse_moved(self, x, y, dx, dy)
  self.hovered_button = nil
  self.hovered_recent = nil

  for i, btn in ipairs(self.buttons) do
    if x >= btn.x and x < btn.x + btn.w and y >= btn.y and y < btn.y + btn.h then
      self.hovered_button = i; self.cursor = "hand"; core.redraw = true; return
    end
  end
  for i, rect in ipairs(self.recent_rects) do
    if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
      self.hovered_recent = i; self.cursor = "hand"; core.redraw = true; return
    end
  end
  self.cursor = "arrow"
end


return EmptyView
