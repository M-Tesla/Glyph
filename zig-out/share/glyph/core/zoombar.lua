local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"


---@class core.zoombar : core.view
---@field super core.view
local ZoomBar = View:extend()

function ZoomBar:__tostring() return "ZoomBar" end

-- Window control buttons (same as titleview)
local restore_command = {
  symbol = "w", action = function() system.set_window_mode("normal") end
}

local maximize_command = {
  symbol = "W", action = function() system.set_window_mode("maximized") end
}

local title_commands = {
  { symbol = "_", action = function() system.set_window_mode("minimized") end },
  maximize_command,
  { symbol = "X", action = function() core.quit() end },
}


local function bar_height()
  return style.font:get_height() + style.padding.y * 2
end


function ZoomBar:new()
  ZoomBar.super.new(self)
  self.visible = true
  self.hovered_item = nil     -- window controls hover
  self.hovered_zone = nil     -- "breadcrumb_N" or nil
  self.breadcrumb_rects = {}  -- clickable breadcrumb segments
end


function ZoomBar:configure_hit_test(borderless)
  if borderless then
    local h = bar_height()
    local icon_w = style.icon_font:get_width("_")
    local icon_spacing = icon_w
    local controls_width = (icon_w + icon_spacing) * #title_commands + icon_spacing
    system.set_window_hit_test(h, controls_width, icon_spacing)
  else
    system.set_window_hit_test()
  end
end


function ZoomBar:on_scale_change()
  self:configure_hit_test(self.visible)
end


function ZoomBar:update()
  self.size.y = self.visible and bar_height() or 0
  title_commands[2] = core.window_mode == "maximized" and restore_command or maximize_command
  ZoomBar.super.update(self)
end


function ZoomBar:get_breadcrumb_parts()
  local parts = {}

  -- Show path to active file, or project name, or "Glyph"
  local view = core.active_view
  if view and view.get_filename then
    local filename = view:get_filename() or view:get_name()
    if filename and filename ~= "---" then
      -- Make path relative to project dir
      if core.project_directories and #core.project_directories > 0 then
        local pdir = core.project_directories[1].name
        if filename:sub(1, #pdir) == pdir then
          filename = filename:sub(#pdir + 2)  -- skip dir + separator
        end
      end
      for segment in filename:gmatch("[^/\\]+") do
        table.insert(parts, segment)
      end
    end
  end

  if #parts == 0 then
    -- Fallback: project name or "Glyph"
    if core.project_directories and #core.project_directories > 0 then
      local dir = core.project_directories[1]
      local name = dir.name:match("[/\\]([^/\\]+)$") or dir.name
      table.insert(parts, name)
    else
      table.insert(parts, "Glyph")
    end
  end

  return parts
end


function ZoomBar:draw_breadcrumb(start_x)
  local _, y_offset = self:get_content_offset()
  local h = bar_height()
  local parts = self:get_breadcrumb_parts()
  local sep_color = style.dim
  local x = start_x

  self.breadcrumb_rects = {}
  local sep = " > "

  for i, part in ipairs(parts) do
    if i > 1 then
      x = common.draw_text(style.font, sep_color, sep, nil, x, y_offset, 0, h)
    end
    local is_last = (i == #parts)
    local is_hovered = (self.hovered_zone == "breadcrumb_" .. i)
    local color = is_hovered and (style.accent or style.caret or style.text)
      or (is_last and style.text or style.dim)

    local part_w = style.font:get_width(part)
    table.insert(self.breadcrumb_rects, { x = x, y = y_offset, w = part_w, h = h, index = i })
    x = common.draw_text(style.font, color, part, nil, x, y_offset, 0, h)
  end
end


function ZoomBar:each_control_item()
  local icon_h = style.icon_font:get_height()
  local icon_w = style.icon_font:get_width("_")
  local icon_spacing = icon_w
  local ox, oy = self:get_content_offset()
  ox = ox + self.size.x
  local i, n = 0, #title_commands
  return function()
    i = i + 1
    if i <= n then
      local dx = -(icon_w + icon_spacing) * (n - i + 1)
      local dy = style.padding.y
      return title_commands[i], ox + dx, oy + dy, icon_w, icon_h
    end
  end
end


function ZoomBar:draw_window_controls()
  for item, x, y, w, h in self:each_control_item() do
    local color = item == self.hovered_item and style.text or style.dim
    common.draw_text(style.icon_font, color, item.symbol, nil, x, y, 0, h)
  end
end


function ZoomBar:on_mouse_pressed(button, x, y, clicks)
  local caught = ZoomBar.super.on_mouse_pressed(self, button, x, y, clicks)
  if caught then return end

  if self.hovered_zone and self.hovered_zone:match("^breadcrumb_") then
    -- Click on breadcrumb: open file finder
    command.perform("core:find-file")
  elseif self.hovered_item then
    self.hovered_item.action()
  else
    -- Click on empty area of bar: restore focus to last view
    if core.last_active_view then
      core.set_active_view(core.last_active_view)
    end
  end
end


function ZoomBar:on_mouse_moved(px, py, ...)
  if self.size.y == 0 then return end
  ZoomBar.super.on_mouse_moved(self, px, py, ...)

  self.hovered_item = nil
  self.hovered_zone = nil

  -- Check window controls
  for item, x, y, w, h in self:each_control_item() do
    if px > x and py > y and px <= x + w and py <= y + h then
      self.hovered_item = item
      return
    end
  end

  -- Check breadcrumb segments
  for _, rect in ipairs(self.breadcrumb_rects) do
    if px >= rect.x and px < rect.x + rect.w and py >= rect.y and py < rect.y + rect.h then
      self.hovered_zone = "breadcrumb_" .. rect.index
      return
    end
  end
end


function ZoomBar:draw()
  self:draw_background(style.background2)
  local ox, _ = self:get_content_offset()
  local start_x = ox + style.padding.x
  self:draw_breadcrumb(start_x)
  self:draw_window_controls()
end


return ZoomBar
