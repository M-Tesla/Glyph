-- mod-version:3
-- lsp.lua — Language Server Protocol client for Glyph
-- Supports any LSP server; auto-starts ZLS for .zig files, lua-language-server for .lua
-- Features: diagnostics (gutter + underline), completions popup, hover, go-to-definition
local core     = require "core"
local common   = require "core.common"
local command  = require "core.command"
local keymap   = require "core.keymap"
local style    = require "core.style"
local config   = require "core.config"
local DocView  = require "core.docview"
local Doc      = require "core.doc"
local process  = require "process"
local renderer = require "renderer"

local PATHSEP = PATHSEP or (package.config:sub(1,1))

config.plugins.lsp = common.merge({
  -- Map file extension → server command
  servers = {
    zig = { cmd = "zls", name = "ZLS" },
    lua = { cmd = "lua-language-server", name = "LuaLS" },
  },
  -- Max completions shown
  max_completions = 10,
  -- Trigger completion after typing these chars
  trigger_chars = { ".", ":", "@" },
}, config.plugins.lsp)

---------------------------------------------------------------------------
-- JSON encode/decode (minimal, sufficient for LSP)
---------------------------------------------------------------------------
local json = {}

local function json_encode(v)
  local t = type(v)
  if t == "nil"     then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number"  then return tostring(v)
  elseif t == "string"  then
    return '"' .. v:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t') .. '"'
  elseif t == "table" then
    -- array check
    if #v > 0 then
      local parts = {}
      for _, item in ipairs(v) do table.insert(parts, json_encode(item)) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, val in pairs(v) do
        table.insert(parts, json_encode(tostring(k)) .. ":" .. json_encode(val))
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

-- Very small JSON decoder (handles what LSP servers actually send)
local function json_decode(s)
  local pos = 1
  local function skip_ws()
    while pos <= #s and s:sub(pos,pos):match("%s") do pos = pos + 1 end
  end
  local parse  -- forward decl
  local function parse_str()
    pos = pos + 1  -- skip "
    local start = pos
    local result = {}
    while pos <= #s do
      local c = s:sub(pos, pos)
      if c == '"' then pos = pos + 1; break
      elseif c == '\\' then
        pos = pos + 1
        local e = s:sub(pos, pos)
        if     e == 'n' then table.insert(result, '\n')
        elseif e == 't' then table.insert(result, '\t')
        elseif e == 'r' then table.insert(result, '\r')
        elseif e == '"' then table.insert(result, '"')
        elseif e == '\\' then table.insert(result, '\\')
        else table.insert(result, e) end
        pos = pos + 1
      else
        table.insert(result, c); pos = pos + 1
      end
    end
    return table.concat(result)
  end
  local function parse_num()
    local start = pos
    if s:sub(pos,pos) == '-' then pos = pos + 1 end
    while pos <= #s and s:sub(pos,pos):match("[%d%.eE%+%-]") do pos = pos + 1 end
    return tonumber(s:sub(start, pos - 1))
  end
  local function parse_arr()
    pos = pos + 1; local arr = {}
    skip_ws()
    if s:sub(pos,pos) == ']' then pos = pos + 1; return arr end
    while true do
      skip_ws(); table.insert(arr, parse()); skip_ws()
      local c = s:sub(pos,pos)
      if c == ']' then pos = pos + 1; break
      elseif c == ',' then pos = pos + 1 end
    end
    return arr
  end
  local function parse_obj()
    pos = pos + 1; local obj = {}
    skip_ws()
    if s:sub(pos,pos) == '}' then pos = pos + 1; return obj end
    while true do
      skip_ws()
      local k = parse_str(); skip_ws()
      pos = pos + 1  -- skip :
      skip_ws()
      obj[k] = parse(); skip_ws()
      local c = s:sub(pos,pos)
      if c == '}' then pos = pos + 1; break
      elseif c == ',' then pos = pos + 1 end
    end
    return obj
  end
  parse = function()
    skip_ws()
    local c = s:sub(pos, pos)
    if c == '"' then return parse_str()
    elseif c == '[' then return parse_arr()
    elseif c == '{' then return parse_obj()
    elseif c == 'n' then pos = pos + 4; return nil
    elseif c == 't' then pos = pos + 4; return true
    elseif c == 'f' then pos = pos + 5; return false
    else return parse_num() end
  end
  local ok, res = pcall(parse)
  return ok and res or nil
end

---------------------------------------------------------------------------
-- LSP Server instance
---------------------------------------------------------------------------
local Server = {}
Server.__index = Server

function Server.new(ext, cfg)
  local s = setmetatable({}, Server)
  s.ext         = ext
  s.cmd         = cfg.cmd
  s.name        = cfg.name or cfg.cmd
  s.proc        = nil
  s.initialized = false
  s.req_id      = 0
  s.pending     = {}   -- id → callback
  s.buf         = ""   -- read buffer
  s.diagnostics = {}   -- uri → array of {range, message, severity}
  s.open_docs   = {}   -- uri → version
  return s
end

function Server:start()
  if self.proc then return end
  local ok, proc = pcall(process.start, { self.cmd }, {
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
    stdin  = process.REDIRECT_PIPE,
  })
  if not ok or not proc then
    core.log("[LSP] Failed to start " .. self.name .. ": " .. tostring(proc))
    return
  end
  self.proc = proc
  core.log("[LSP] Started " .. self.name)
  -- Start reader coroutine
  core.add_thread(function() self:reader_loop() end)
  -- Send initialize
  self:request("initialize", {
    processId = nil,
    rootUri   = self:path_to_uri(
      core.project_directories and #core.project_directories > 0
      and core.project_directories[1].name or nil
    ),
    capabilities = {
      textDocument = {
        synchronization = { didSave = true, dynamicRegistration = false },
        completion      = { completionItem = { snippetSupport = false } },
        publishDiagnostics = { relatedInformation = false },
        hover           = {},
        definition      = {},
      },
    },
    clientInfo = { name = "Glyph", version = "0.1" },
  }, function(result)
    self.initialized = true
    self:notify("initialized", {})
    core.log("[LSP] " .. self.name .. " initialized.")
  end)
end

function Server:stop()
  if self.proc then
    pcall(function() self.proc:terminate() end)
    self.proc = nil
    self.initialized = false
  end
end

function Server:path_to_uri(path)
  if not path then return nil end
  path = path:gsub("\\", "/")
  if path:sub(1,1) ~= "/" then path = "/" .. path end
  return "file://" .. path
end

function Server:uri_to_path(uri)
  local p = uri:gsub("^file://", ""):gsub("/", PATHSEP)
  -- Windows: /C:/... → C:/...
  if p:sub(1,1) == PATHSEP and p:sub(3,3) == ":" then p = p:sub(2) end
  return p
end

function Server:send_raw(msg)
  if not self.proc then return end
  local json_str = json_encode(msg)
  local header   = "Content-Length: " .. #json_str .. "\r\n\r\n"
  pcall(function() self.proc:write(header .. json_str) end)
end

function Server:request(method, params, callback)
  self.req_id = self.req_id + 1
  local id = self.req_id
  if callback then self.pending[id] = callback end
  self:send_raw({ jsonrpc = "2.0", id = id, method = method, params = params })
  return id
end

function Server:notify(method, params)
  self:send_raw({ jsonrpc = "2.0", method = method, params = params })
end

function Server:reader_loop()
  while self.proc do
    local ok, data = pcall(function() return self.proc:read_stdout(4096) end)
    if ok and data and #data > 0 then
      self.buf = self.buf .. data
      self:process_buf()
    end
    -- Also drain stderr to prevent blocking
    pcall(function() self.proc:read_stderr(1024) end)
    coroutine.yield(0.01)
  end
end

function Server:process_buf()
  while true do
    -- Parse Content-Length header
    local _, hdr_end, len_str = self.buf:find("Content%-Length: (%d+)\r\n\r\n")
    if not hdr_end then break end
    local len = tonumber(len_str)
    if #self.buf < hdr_end + len then break end  -- wait for more data
    local body = self.buf:sub(hdr_end + 1, hdr_end + len)
    self.buf = self.buf:sub(hdr_end + len + 1)
    local msg = json_decode(body)
    if msg then self:on_message(msg) end
  end
end

function Server:on_message(msg)
  if msg.id and self.pending[msg.id] then
    -- Response to our request
    local cb = self.pending[msg.id]
    self.pending[msg.id] = nil
    if msg.result ~= nil then cb(msg.result)
    elseif msg.error then
      core.log("[LSP] " .. self.name .. " error: " .. (msg.error.message or "?"))
    end
  elseif msg.method then
    -- Notification from server
    self:on_notification(msg.method, msg.params)
  end
end

function Server:on_notification(method, params)
  if method == "textDocument/publishDiagnostics" then
    local uri  = params and params.uri or ""
    local diags = params and params.diagnostics or {}
    self.diagnostics[uri] = diags
    core.redraw = true
  end
end

---------------------------------------------------------------------------
-- Document synchronization
---------------------------------------------------------------------------
function Server:doc_uri(doc)
  return self:path_to_uri(doc.abs_filename or doc.filename)
end

function Server:did_open(doc)
  if not self.initialized then return end
  local uri = self:doc_uri(doc)
  if self.open_docs[uri] then return end
  self.open_docs[uri] = 1
  self:notify("textDocument/didOpen", {
    textDocument = {
      uri        = uri,
      languageId = doc.filename and doc.filename:match("%.(%w+)$") or "text",
      version    = 1,
      text       = doc:get_text(1, 1, #doc.lines, #doc.lines[#doc.lines]),
    },
  })
end

function Server:did_change(doc)
  if not self.initialized then return end
  local uri = self:doc_uri(doc)
  local ver = (self.open_docs[uri] or 0) + 1
  self.open_docs[uri] = ver
  self:notify("textDocument/didChange", {
    textDocument   = { uri = uri, version = ver },
    contentChanges = {{ text = doc:get_text(1, 1, #doc.lines, #doc.lines[#doc.lines]) }},
  })
end

function Server:get_completions(doc, line, col, callback)
  if not self.initialized then return end
  self:did_open(doc)
  self:request("textDocument/completion", {
    textDocument = { uri = self:doc_uri(doc) },
    position     = { line = line - 1, character = col - 1 },
  }, callback)
end

function Server:get_definition(doc, line, col, callback)
  if not self.initialized then return end
  self:did_open(doc)
  self:request("textDocument/definition", {
    textDocument = { uri = self:doc_uri(doc) },
    position     = { line = line - 1, character = col - 1 },
  }, callback)
end

function Server:get_hover(doc, line, col, callback)
  if not self.initialized then return end
  self:did_open(doc)
  self:request("textDocument/hover", {
    textDocument = { uri = self:doc_uri(doc) },
    position     = { line = line - 1, character = col - 1 },
  }, callback)
end

function Server:get_code_actions(doc, line, col, callback)
  if not self.initialized then return end
  self:did_open(doc)
  local uri   = self:doc_uri(doc)
  local diags = {}
  for _, d in ipairs(self.diagnostics[uri] or {}) do
    if d.range and d.range.start and d.range.start.line + 1 == line then
      table.insert(diags, d)
    end
  end
  self:request("textDocument/codeAction", {
    textDocument = { uri = uri },
    range = {
      start = { line = line - 1, character = col - 1 },
      ["end"] = { line = line - 1, character = col },
    },
    context = { diagnostics = diags },
  }, callback)
end

function Server:get_signature_help(doc, line, col, callback)
  if not self.initialized then return end
  self:did_open(doc)
  self:request("textDocument/signatureHelp", {
    textDocument = { uri = self:doc_uri(doc) },
    position     = { line = line - 1, character = col - 1 },
  }, callback)
end

function Server:get_references(doc, line, col, callback)
  if not self.initialized then return end
  self:did_open(doc)
  self:request("textDocument/references", {
    textDocument = { uri = self:doc_uri(doc) },
    position     = { line = line - 1, character = col - 1 },
    context      = { includeDeclaration = true },
  }, callback)
end

---------------------------------------------------------------------------
-- Server registry
---------------------------------------------------------------------------
local servers = {}  -- ext → Server

local function get_server(ext)
  if not ext then return nil end
  if servers[ext] then return servers[ext] end
  local cfg = config.plugins.lsp.servers[ext]
  if not cfg then return nil end
  local s = Server.new(ext, cfg)
  servers[ext] = s
  s:start()
  return s
end

local function server_for_doc(doc)
  if not doc or not doc.filename then return nil end
  local ext = doc.filename:match("%.(%w+)$")
  return ext and get_server(ext:lower()) or nil
end

---------------------------------------------------------------------------
-- Diagnostics: draw underlines in DocView
---------------------------------------------------------------------------
local draw_line_text_orig = DocView.draw_line_text

function DocView:draw_line_text(line, x, y)
  local lh = draw_line_text_orig(self, line, x, y)
  local srv = server_for_doc(self.doc)
  if not srv then return lh end
  local uri   = srv:doc_uri(self.doc)
  local diags = srv.diagnostics[uri]
  if not diags then return lh end

  local font = self:get_font()
  local fh   = font:get_height()

  for _, d in ipairs(diags) do
    local dline = (d.range and d.range.start and d.range.start.line or 0) + 1
    if dline == line then
      local sc  = (d.range.start.character or 0)
      local ec  = (d.range["end"] and d.range["end"].character or sc + 1)
      local sev = d.severity or 1
      local col = sev == 1 and { 220, 60, 60, 200 }
               or sev == 2 and { 230, 180, 50, 200 }
               or                { 100, 180, 220, 180 }
      -- Get x positions
      local line_text = self.doc.lines[line] or ""
      local x1 = x + font:get_width(line_text:sub(1, sc))
      local x2 = x + font:get_width(line_text:sub(1, ec))
      -- Draw squiggly underline (simple: dashed rect at baseline)
      local uy = y + fh - 2
      local uw = math.max(4, x2 - x1)
      local seg = 4
      for sx = x1, x1 + uw - 1, seg * 2 do
        renderer.draw_rect(sx, uy, math.min(seg, x1 + uw - sx), 1, col)
      end
    end
  end
  return lh
end

---------------------------------------------------------------------------
-- Diagnostics count in gutter (dot marker)
---------------------------------------------------------------------------
local draw_gutter_orig = DocView.draw_line_gutter

function DocView:draw_line_gutter(line, x, y, width)
  local lh = draw_gutter_orig(self, line, x, y, width)
  local srv = server_for_doc(self.doc)
  if not srv then return lh end
  local uri   = srv:doc_uri(self.doc)
  local diags = srv.diagnostics[uri]
  if not diags then return lh end

  for _, d in ipairs(diags) do
    local dline = (d.range and d.range.start and d.range.start.line or 0) + 1
    if dline == line then
      local sev = d.severity or 1
      local col = sev == 1 and { 220, 60, 60, 255 }
               or sev == 2 and { 230, 180, 50, 255 }
               or                { 100, 180, 220, 200 }
      local dot_size = 5
      renderer.draw_rect(x + 2, y + math.floor((lh - dot_size) / 2), dot_size, dot_size, col)
      break
    end
  end
  return lh
end

---------------------------------------------------------------------------
-- Completions popup
---------------------------------------------------------------------------
local completion_state = {
  active    = false,
  items     = {},
  sel       = 1,
  view      = nil,
  doc       = nil,
  trigger_line = 0,
  trigger_col  = 0,
}

local function completions_hide()
  completion_state.active = false
  completion_state.items  = {}
  core.redraw = true
end

local function completions_show(view, items, line, col)
  if not items or #items == 0 then completions_hide(); return end
  -- Normalize items (can be array or completionList)
  local list = items.items or items
  if type(list) ~= "table" then completions_hide(); return end
  completion_state.active = true
  completion_state.view   = view
  completion_state.doc    = view.doc
  completion_state.items  = list
  completion_state.sel    = 1
  completion_state.trigger_line = line
  completion_state.trigger_col  = col
  core.redraw = true
end

local function completions_apply(view)
  if not completion_state.active then return end
  local item = completion_state.items[completion_state.sel]
  if not item then completions_hide(); return end
  local label = (item.insertText or item.label or "")
  -- Insert at current cursor
  local doc = view.doc
  local line, col = doc:get_selection()
  -- Replace from trigger position to current col
  local trig_col = completion_state.trigger_col
  if col > trig_col then doc:remove(line, trig_col, line, col) end
  doc:insert(line, trig_col, label)
  completions_hide()
end

---------------------------------------------------------------------------
-- Hover popup
---------------------------------------------------------------------------
local hover_state = {
  active = false,
  lines  = {},   -- wrapped text lines
  view   = nil,
  ax = 0, ay = 0,  -- screen anchor (below cursor)
}

local function hover_hide()
  if not hover_state.active then return end
  hover_state.active = false
  hover_state.lines  = {}
  core.redraw = true
end

local function hover_show(view, text, ax, ay)
  if not text or text == "" then hover_hide(); return end
  -- Strip markdown fences and backticks
  text = text:gsub("```%w*%s*\n?", ""):gsub("```%s*\n?", ""):gsub("`", "")
  text = text:match("^%s*(.-)%s*$") or ""
  if text == "" then hover_hide(); return end
  -- Word-wrap at 55 chars
  local lines = {}
  for para in (text .. "\n"):gmatch("([^\n]*)\n") do
    if para == "" then
      if #lines > 0 and lines[#lines] ~= "" then table.insert(lines, "") end
    elseif #para <= 55 then
      table.insert(lines, para)
    else
      local cur = ""
      for word in para:gmatch("%S+") do
        if #cur + #word + 1 > 55 then
          if cur ~= "" then table.insert(lines, cur) end
          cur = word
        else
          cur = cur == "" and word or (cur .. " " .. word)
        end
      end
      if cur ~= "" then table.insert(lines, cur) end
    end
    if #lines >= 20 then break end
  end
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  if #lines == 0 then hover_hide(); return end
  hover_state.active = true
  hover_state.view   = view
  hover_state.lines  = lines
  hover_state.ax     = ax
  hover_state.ay     = ay
  core.redraw = true
end

---------------------------------------------------------------------------
-- Code Actions popup
---------------------------------------------------------------------------
local ca_state = {
  active     = false,
  items      = {},
  sel        = 1,
  view       = nil,
  ax = 0, ay = 0,
  item_rects = {},
}

local function ca_hide()
  if not ca_state.active then return end
  ca_state.active = false
  ca_state.items  = {}
  ca_state.item_rects = {}
  core.redraw = true
end

local function ca_show(view, items, ax, ay)
  if not items or #items == 0 then ca_hide(); return end
  ca_state.active = true
  ca_state.items  = items
  ca_state.sel    = 1
  ca_state.view   = view
  ca_state.ax     = ax
  ca_state.ay     = ay
  ca_state.item_rects = {}
  core.redraw = true
end

local function ca_apply(view)
  if not ca_state.active then return end
  local action = ca_state.items[ca_state.sel]
  if not action then ca_hide(); return end
  local srv = server_for_doc(view.doc)
  if action.edit and action.edit.changes then
    for uri, edits in pairs(action.edit.changes) do
      if not srv then break end
      local path   = srv:uri_to_path(uri)
      local target = core.open_doc(path)
      table.sort(edits, function(a, b)
        local al, bl = a.range.start.line, b.range.start.line
        if al ~= bl then return al > bl end
        return a.range.start.character > b.range.start.character
      end)
      for _, edit in ipairs(edits) do
        local sl = edit.range.start.line + 1
        local sc = edit.range.start.character + 1
        local el = edit.range["end"].line + 1
        local ec = edit.range["end"].character + 1
        target:remove(sl, sc, el, ec)
        target:insert(sl, sc, edit.newText or "")
      end
    end
  elseif action.command and srv then
    local cmd = type(action.command) == "table" and action.command or action
    srv:request("workspace/executeCommand", {
      command   = cmd.command,
      arguments = cmd.arguments,
    }, function() core.redraw = true end)
  end
  ca_hide()
end

---------------------------------------------------------------------------
-- Signature Help popup
---------------------------------------------------------------------------
local sig_state = {
  active   = false,
  label    = "",
  params   = {},  -- { {s, e}, ... } byte offsets in label (0-indexed)
  active_p = 0,   -- active parameter index (0-indexed)
  view     = nil,
  ax = 0, ay = 0,
}

local function sig_hide()
  if not sig_state.active then return end
  sig_state.active = false
  core.redraw = true
end

local function sig_show(view, result, ax, ay)
  if not result or not result.signatures or #result.signatures == 0 then
    sig_hide(); return
  end
  local idx  = (result.activeSignature or 0) + 1
  local sig  = result.signatures[idx] or result.signatures[1]
  local label = sig.label or ""
  local params = {}
  if sig.parameters then
    for _, p in ipairs(sig.parameters) do
      if type(p.label) == "table" then
        table.insert(params, { p.label[1], p.label[2] })
      elseif type(p.label) == "string" then
        local s = label:find(p.label, 1, true)
        if s then table.insert(params, { s - 1, s - 1 + #p.label }) end
      end
    end
  end
  sig_state.active   = true
  sig_state.label    = label
  sig_state.params   = params
  sig_state.active_p = result.activeParameter or sig.activeParameter or 0
  sig_state.view     = view
  sig_state.ax       = ax
  sig_state.ay       = ay
  core.redraw = true
end

-- Draw completions popup (hooked into DocView:draw_overlay)
local draw_overlay_orig = DocView.draw_overlay or function() end

function DocView:draw_overlay()
  draw_overlay_orig(self)

  -- ── Completions popup ─────────────────────────────────────────────────
  if completion_state.active and completion_state.view == self then

  local font    = self:get_font()
  local lh      = font:get_height() + 4
  local pad     = style.padding.x
  local n       = math.min(#completion_state.items, config.plugins.lsp.max_completions)
  local pop_w   = 220
  local pop_h   = n * lh + 4
  local accent  = style.accent or style.caret or style.text

  -- Position popup below cursor
  local line, col = self.doc:get_selection()
  local cx, cy = self:get_line_screen_position(line, col)
  local lht    = self:get_line_height()
  local px     = math.min(cx, self.position.x + self.size.x - pop_w - 4)
  local py     = cy + lht + 2
  if py + pop_h > self.position.y + self.size.y then
    py = cy - pop_h - 2
  end

  renderer.draw_rect(px, py, pop_w, pop_h, style.background2 or style.background)
  renderer.draw_rect(px, py, pop_w, 1, style.dim)
  renderer.draw_rect(px, py + pop_h - 1, pop_w, 1, style.dim)

  for i = 1, n do
    local item = completion_state.items[i]
    local iy   = py + 2 + (i - 1) * lh
    if i == completion_state.sel then
      renderer.draw_rect(px, iy, pop_w, lh, { accent[1], accent[2], accent[3], 35 })
    end
    local label = item.label or ""
    local kind  = item.kind  -- 1=text,2=method,3=function,6=variable,etc.
    local kind_str = kind == 3 and "fn" or kind == 6 and "var" or kind == 9 and "mod" or ""
    local col_label = i == completion_state.sel and style.text or style.dim
    renderer.draw_text(font, label, px + 4, iy + 2, col_label)
    if kind_str ~= "" then
      local kw = font:get_width(kind_str)
      renderer.draw_text(font, kind_str, px + pop_w - kw - 4, iy + 2, style.dim)
    end
  end
  end  -- end completion_state.active block

  -- ── Hover popup ──────────────────────────────────────────────────────
  if hover_state.active and hover_state.view == self then
    local hfont   = self:get_font()
    local hlh     = hfont:get_height() + 4
    local hpad    = style.padding.x
    -- Measure popup width from longest line
    local hpop_w  = 160
    for _, ln in ipairs(hover_state.lines) do
      local lw = hfont:get_width(ln) + hpad * 2
      if lw > hpop_w then hpop_w = lw end
    end
    hpop_w = math.min(hpop_w, self.size.x - 20)
    local hpop_h = #hover_state.lines * hlh + 6

    -- Position: prefer below cursor, flip above if no room
    local hx = math.min(hover_state.ax, self.position.x + self.size.x - hpop_w - 4)
    local hy = hover_state.ay
    if hy + hpop_h > self.position.y + self.size.y - 4 then
      hy = hover_state.ay - self:get_line_height() - hpop_h - 4
    end
    hx = math.max(self.position.x + 2, hx)
    hy = math.max(self.position.y + 2, hy)

    local bg = style.background2 or style.background
    renderer.draw_rect(hx, hy, hpop_w, hpop_h, bg)
    renderer.draw_rect(hx,              hy,              hpop_w, 1, style.dim)
    renderer.draw_rect(hx,              hy + hpop_h - 1, hpop_w, 1, style.dim)
    renderer.draw_rect(hx,              hy,              1, hpop_h, style.dim)
    renderer.draw_rect(hx + hpop_w - 1, hy,              1, hpop_h, style.dim)

    for i, ln in ipairs(hover_state.lines) do
      local ty  = hy + 3 + (i - 1) * hlh
      local col = ln == "" and style.dim or style.text
      renderer.draw_text(hfont, ln, hx + hpad, ty, col)
    end
  end

  -- ── Code Actions popup ───────────────────────────────────────────────
  if ca_state.active and ca_state.view == self then
    local cfont  = self:get_font()
    local clh    = cfont:get_height() + 4
    local cpad   = style.padding.x
    local cpop_w = 260
    for _, a in ipairs(ca_state.items) do
      local t = a.title or (type(a.command) == "table" and a.command.title) or "?"
      local tw = cfont:get_width(t) + cpad * 2
      if tw > cpop_w then cpop_w = tw end
    end
    cpop_w = math.min(cpop_w, self.size.x - 20)
    local n     = #ca_state.items
    local cpop_h = n * clh + 4
    local cx = math.min(ca_state.ax, self.position.x + self.size.x - cpop_w - 4)
    local cy = ca_state.ay
    if cy + cpop_h > self.position.y + self.size.y then
      cy = ca_state.ay - self:get_line_height() - cpop_h - 2
    end
    cx = math.max(self.position.x + 2, cx)
    cy = math.max(self.position.y + 2, cy)
    ca_state.item_rects = {}
    local accent = style.accent or style.caret or style.text
    renderer.draw_rect(cx, cy, cpop_w, cpop_h, style.background2 or style.background)
    renderer.draw_rect(cx, cy, cpop_w, 1, style.dim)
    renderer.draw_rect(cx, cy + cpop_h - 1, cpop_w, 1, style.dim)
    for i, action in ipairs(ca_state.items) do
      local title = action.title or (type(action.command) == "table" and action.command.title) or "?"
      local iy    = cy + 2 + (i - 1) * clh
      if i == ca_state.sel then
        renderer.draw_rect(cx, iy, cpop_w, clh, { accent[1], accent[2], accent[3], 40 })
      end
      renderer.draw_text(cfont, title, cx + cpad, iy + 2,
        i == ca_state.sel and style.text or style.dim)
      ca_state.item_rects[i] = { x = cx, y = iy, w = cpop_w, h = clh }
    end
  end

  -- ── Signature Help ───────────────────────────────────────────────────
  if sig_state.active and sig_state.view == self then
    local sfont = self:get_font()
    local slh   = sfont:get_height() + 4
    local spad  = style.padding.x
    local label = sig_state.label
    local sw    = math.min(sfont:get_width(label) + spad * 2, self.size.x - 20)
    local sh    = slh + 4
    local sx    = math.min(sig_state.ax, self.position.x + self.size.x - sw - 4)
    local sy    = sig_state.ay - sh - 4   -- default: above cursor
    if sy < self.position.y + 2 then
      sy = sig_state.ay + self:get_line_height() + 2
    end
    sx = math.max(self.position.x + 2, sx)
    renderer.draw_rect(sx, sy, sw, sh, style.background2 or style.background)
    renderer.draw_rect(sx, sy, sw, 1, style.dim)
    renderer.draw_rect(sx, sy + sh - 1, sw, 1, style.dim)
    local p  = sig_state.params[sig_state.active_p + 1]
    local tx = sx + spad
    local ty = sy + 3
    local accent = style.accent or style.caret or style.text
    if not p or #sig_state.params == 0 then
      renderer.draw_text(sfont, label, tx, ty, style.dim)
    else
      -- text before active param
      if p[1] > 0 then
        local pre = label:sub(1, p[1])
        renderer.draw_text(sfont, pre, tx, ty, style.dim)
        tx = tx + sfont:get_width(pre)
      end
      -- active param highlighted
      local param_text = label:sub(p[1] + 1, p[2])
      renderer.draw_text(sfont, param_text, tx, ty, accent)
      tx = tx + sfont:get_width(param_text)
      -- text after active param
      if p[2] < #label then
        renderer.draw_text(sfont, label:sub(p[2] + 1), tx, ty, style.dim)
      end
    end
  end
end

---------------------------------------------------------------------------
-- Hook into DocView to trigger completions on typing
---------------------------------------------------------------------------
local change_timer = setmetatable({}, { __mode = "k" })

local doc_text_input_orig = Doc.text_input
function Doc:text_input(text, idx)
  doc_text_input_orig(self, text, idx)
  -- Debounced didChange
  change_timer[self] = system.get_time()
  -- Hide hover and code actions on any keystroke
  hover_hide()
  ca_hide()
  -- Auto-trigger completions on trigger characters
  local srv = server_for_doc(self)
  if srv and srv.initialized then
    local av = core.active_view
    local line, col = self:get_selection()
    -- Completion trigger chars
    for _, tc in ipairs(config.plugins.lsp.trigger_chars) do
      if text == tc then
        if av and av.doc == self then
          srv:get_completions(self, line, col, function(result)
            completions_show(av, result, line, col)
          end)
        end
        break
      end
    end
    -- Signature help: trigger on ( or ,
    if text == "(" or text == "," then
      if av and av.doc == self then
        local ax, ay = av:get_line_screen_position(line, col)
        srv:get_signature_help(self, line, col, function(result)
          sig_show(av, result, ax, ay)
        end)
      end
    elseif text == ")" then
      sig_hide()
    end
  end
end

-- Periodic: send didChange + maybe trigger completion
core.add_thread(function()
  while true do
    for doc, t in pairs(change_timer) do
      if system.get_time() - t > 0.3 then
        change_timer[doc] = nil
        local srv = server_for_doc(doc)
        if srv then srv:did_change(doc) end
      end
    end
    coroutine.yield(0.1)
  end
end)

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
command.add("core.docview!", {
  ["lsp:complete"] = function()
    local av  = core.active_view
    local doc = av.doc
    local srv = server_for_doc(doc)
    if not srv then core.log("[LSP] No server for this file type."); return end
    srv:did_open(doc)
    local line, col = doc:get_selection()
    srv:get_completions(doc, line, col, function(result)
      completions_show(av, result, line, col)
    end)
  end,

  ["lsp:goto-definition"] = function()
    local av  = core.active_view
    local doc = av.doc
    local srv = server_for_doc(doc)
    if not srv then return end
    srv:did_open(doc)
    local line, col = doc:get_selection()
    srv:get_definition(doc, line, col, function(result)
      if not result then core.log("[LSP] No definition found."); return end
      local loc = type(result) == "table" and (result[1] or result) or nil
      if not loc or not loc.uri then return end
      local path = srv:uri_to_path(loc.uri)
      local target_line = loc.range and loc.range.start and (loc.range.start.line + 1) or 1
      local target_doc  = core.open_doc(path)
      core.root_view:open_doc(target_doc)
      target_doc:set_selection(target_line, 1)
    end)
  end,

  ["lsp:completion-up"]     = function()
    if not completion_state.active then return end
    completion_state.sel = math.max(1, completion_state.sel - 1); core.redraw = true
  end,
  ["lsp:completion-down"]   = function()
    if not completion_state.active then return end
    local n = math.min(#completion_state.items, config.plugins.lsp.max_completions)
    completion_state.sel = math.min(n, completion_state.sel + 1); core.redraw = true
  end,
  ["lsp:completion-accept"] = function()
    if not completion_state.active then return end
    completions_apply(core.active_view)
  end,
  ["lsp:completion-dismiss"] = function()
    completions_hide()
  end,

  ["lsp:rename"] = function()
    local av  = core.active_view
    local doc = av.doc
    local srv = server_for_doc(doc)
    if not srv then core.log("[LSP] No server for this file type."); return end
    srv:did_open(doc)
    local line, col = doc:get_selection()
    -- Grab word under cursor as default hint
    local ln_text = doc.lines[line] or ""
    local s, e = col, col
    while s > 1 and ln_text:sub(s-1, s-1):match("[%w_]") do s = s - 1 end
    while e <= #ln_text and ln_text:sub(e, e):match("[%w_]") do e = e + 1 end
    local word = ln_text:sub(s, e - 1)
    core.command_view:enter("Rename '" .. word .. "' to", function(new_name)
      if not new_name or new_name == "" then return end
      srv:request("textDocument/rename", {
        textDocument = { uri = srv:doc_uri(doc) },
        position     = { line = line - 1, character = col - 1 },
        newName      = new_name,
      }, function(result)
        if not result then core.log("[LSP] Rename not supported."); return end
        -- Normalize: result.changes or result.documentChanges
        local changes = result.changes or {}
        if result.documentChanges then
          changes = {}
          for _, dc in ipairs(result.documentChanges) do
            if dc.textDocument and dc.edits then
              changes[dc.textDocument.uri] = dc.edits
            end
          end
        end
        if not next(changes) then core.log("[LSP] No rename edits returned."); return end
        local count = 0
        for uri, edits in pairs(changes) do
          local path   = srv:uri_to_path(uri)
          local target = core.open_doc(path)
          table.sort(edits, function(a, b)
            local al, bl = a.range.start.line, b.range.start.line
            if al ~= bl then return al > bl end
            return a.range.start.character > b.range.start.character
          end)
          for _, edit in ipairs(edits) do
            local sl = edit.range.start.line + 1
            local sc = edit.range.start.character + 1
            local el = edit.range["end"].line + 1
            local ec = edit.range["end"].character + 1
            target:remove(sl, sc, el, ec)
            target:insert(sl, sc, edit.newText or "")
            count = count + 1
          end
        end
        core.log("[LSP] Renamed '" .. word .. "' → '" .. new_name .. "' (" .. count .. " changes)")
      end)
    end)
  end,

  ["lsp:find-references"] = function()
    local av  = core.active_view
    local doc = av.doc
    local srv = server_for_doc(doc)
    if not srv then core.log("[LSP] No server for this file type."); return end
    srv:did_open(doc)
    local line, col = doc:get_selection()
    srv:get_references(doc, line, col, function(result)
      if not result or #result == 0 then
        core.log("[LSP] No references found."); return
      end
      -- Single result: jump directly
      if #result == 1 then
        local loc  = result[1]
        local path = srv:uri_to_path(loc.uri)
        local d    = core.open_doc(path)
        core.root_view:open_doc(d)
        d:set_selection(loc.range.start.line + 1, loc.range.start.character + 1)
        return
      end
      -- Multiple: show in command view as selectable list
      local items = {}
      for _, loc in ipairs(result) do
        local path = srv:uri_to_path(loc.uri)
        local rel  = path
        if core.project_dir then
          local prefix = core.project_dir .. PATHSEP
          if path:sub(1, #prefix) == prefix then rel = path:sub(#prefix + 1) end
        end
        local lnum = loc.range.start.line + 1
        table.insert(items, { text = rel, info = ":" .. lnum, loc = loc, path = path })
      end
      core.command_view:enter("References (" .. #items .. ")", function(_, item)
        if not item then return end
        local d = core.open_doc(item.path)
        core.root_view:open_doc(d)
        d:set_selection(item.loc.range.start.line + 1, item.loc.range.start.character + 1)
      end, function(text)
        if text == "" then return items end
        local res = {}
        for _, it in ipairs(items) do
          if it.text:lower():find(text:lower(), 1, true) then
            table.insert(res, it)
          end
        end
        return res
      end)
    end)
  end,

  ["lsp:code-action"] = function()
    if ca_state.active then ca_hide(); return end
    local av  = core.active_view
    local doc = av.doc
    local srv = server_for_doc(doc)
    if not srv then core.log("[LSP] No server for this file type."); return end
    srv:did_open(doc)
    local line, col = doc:get_selection()
    local ax, ay    = av:get_line_screen_position(line, col)
    local lht       = av:get_line_height()
    srv:get_code_actions(doc, line, col, function(result)
      if not result or #result == 0 then
        core.log("[LSP] No code actions available."); return
      end
      ca_show(av, result, ax, ay + lht + 2)
    end)
  end,

  ["lsp:sig-help"] = function()
    if sig_state.active then sig_hide(); return end
    local av  = core.active_view
    local doc = av.doc
    local srv = server_for_doc(doc)
    if not srv then return end
    srv:did_open(doc)
    local line, col = doc:get_selection()
    local ax, ay    = av:get_line_screen_position(line, col)
    srv:get_signature_help(doc, line, col, function(result)
      sig_show(av, result, ax, ay)
    end)
  end,

  ["lsp:hover"] = function()
    -- Toggle: if already showing, hide
    if hover_state.active then hover_hide(); return end
    local av  = core.active_view
    local doc = av.doc
    local srv = server_for_doc(doc)
    if not srv then core.log("[LSP] No server for this file type."); return end
    srv:did_open(doc)
    local line, col = doc:get_selection()
    local ax, ay    = av:get_line_screen_position(line, col)
    local lht       = av:get_line_height()
    srv:get_hover(doc, line, col, function(result)
      if not result or not result.contents then
        core.log("[LSP] No hover info."); return
      end
      local contents = result.contents
      local text = ""
      if type(contents) == "string" then
        text = contents
      elseif type(contents) == "table" then
        if contents.value then
          text = contents.value
        else
          local parts = {}
          for _, c in ipairs(contents) do
            if type(c) == "string" then
              table.insert(parts, c)
            elseif type(c) == "table" and c.value then
              table.insert(parts, c.value)
            end
          end
          text = table.concat(parts, "\n")
        end
      end
      hover_show(av, text, ax, ay + lht + 2)
    end)
  end,
})

keymap.add {
  ["ctrl+space"]       = "lsp:complete",
  ["ctrl+F12"]         = "lsp:goto-definition",
  ["f12"]              = "lsp:goto-definition",
  ["ctrl+k"]           = "lsp:hover",
  ["ctrl+."]           = "lsp:code-action",
  ["ctrl+shift+space"] = "lsp:sig-help",
  ["f2"]               = "lsp:rename",
  ["shift+f12"]        = "lsp:find-references",
}

-- When completion popup is active, intercept arrow keys + enter/escape
keymap.add {
  ["up"]     = { "lsp:completion-up",     "doc:move-to-previous-line" },
  ["down"]   = { "lsp:completion-down",   "doc:move-to-next-line" },
  ["return"] = { "lsp:completion-accept", "doc:newline" },
  ["escape"] = { "lsp:completion-dismiss" },
  ["tab"]    = { "lsp:completion-accept", "doc:indent" },
}

-- Predicate: only intercept when code action popup is visible
command.add(function()
  return ca_state.active
    and core.active_view
    and core.active_view:is(DocView)
end, {
  ["lsp:ca-up"]      = function() ca_state.sel = math.max(1, ca_state.sel - 1); core.redraw = true end,
  ["lsp:ca-down"]    = function() ca_state.sel = math.min(#ca_state.items, ca_state.sel + 1); core.redraw = true end,
  ["lsp:ca-accept"]  = function() ca_apply(core.active_view) end,
  ["lsp:ca-dismiss"] = function() ca_hide() end,
})

keymap.add {
  ["up"]     = { "lsp:ca-up",     "lsp:completion-up",     "doc:move-to-previous-line" },
  ["down"]   = { "lsp:ca-down",   "lsp:completion-down",   "doc:move-to-next-line" },
  ["return"] = { "lsp:ca-accept", "lsp:completion-accept", "doc:newline" },
  ["escape"] = { "lsp:ca-dismiss" },
  ["tab"]    = { "lsp:ca-accept", "lsp:completion-accept", "doc:indent" },
}

-- Predicate: only intercept when hover popup is visible
command.add(function()
  return hover_state.active
    and core.active_view
    and core.active_view:is(DocView)
end, {
  ["lsp:hover-dismiss"] = function() hover_hide() end,
})

keymap.add {
  ["escape"] = { "lsp:hover-dismiss" },
}

-- Predicate: only intercept when completion popup is visible
command.add(function()
  return completion_state.active
    and core.active_view
    and core.active_view:is(DocView)
end, {
  ["lsp:completion-up"]     = function()
    completion_state.sel = math.max(1, completion_state.sel - 1); core.redraw = true
  end,
  ["lsp:completion-down"]   = function()
    local n = math.min(#completion_state.items, config.plugins.lsp.max_completions)
    completion_state.sel = math.min(n, completion_state.sel + 1); core.redraw = true
  end,
  ["lsp:completion-accept"] = function()
    completions_apply(core.active_view)
  end,
  ["lsp:completion-dismiss"] = function()
    completions_hide()
  end,
})

---------------------------------------------------------------------------
-- Auto-open server when a doc is opened/focused
---------------------------------------------------------------------------
local set_active_view_orig2 = core.set_active_view
function core.set_active_view(view)
  set_active_view_orig2(view)
  if view and view.doc then
    local srv = server_for_doc(view.doc)
    if srv and srv.initialized then
      srv:did_open(view.doc)
    end
  end
end

---------------------------------------------------------------------------
-- Status bar: LSP health + diagnostics count
---------------------------------------------------------------------------
if core.status_view then
  pcall(function()
    core.status_view:add_item({
      predicate = function()
        local av = core.active_view
        return av and av:is(DocView) and av.doc ~= nil
      end,
      name      = "lsp:status",
      alignment = 2,  -- RIGHT
      get_item  = function()
        local av = core.active_view
        if not av or not av.doc then return {} end
        local srv = server_for_doc(av.doc)
        if not srv then return {} end
        local col, label
        if not srv.proc then
          label = "[" .. srv.name .. " off]"
          col   = { 180, 60, 60, 200 }
        elseif not srv.initialized then
          label = "[" .. srv.name .. " ...]"
          col   = style.dim
        else
          local uri    = srv:doc_uri(av.doc)
          local diags  = srv.diagnostics[uri] or {}
          local errs, warns = 0, 0
          for _, d in ipairs(diags) do
            if     d.severity == 1 then errs  = errs  + 1
            elseif d.severity == 2 then warns = warns + 1
            end
          end
          if errs > 0 then
            label = srv.name .. " " .. errs .. "E"
            if warns > 0 then label = label .. " " .. warns .. "W" end
            col = { 220, 60, 60, 230 }
          elseif warns > 0 then
            label = srv.name .. " " .. warns .. "W"
            col = { 230, 180, 50, 230 }
          else
            label = srv.name .. " ok"
            col = { 80, 200, 120, 230 }
          end
        end
        return { col, style.font, label }
      end,
    })
  end)
end

core.log("[LSP] Ctrl+Space=complete  F12=def  Ctrl+K=hover  Ctrl+.=fix  Ctrl+Shift+Space=sig")

return {}
