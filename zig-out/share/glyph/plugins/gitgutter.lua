-- mod-version:3
-- gitgutter.lua — Git diff markers in gutter + branch in status bar
-- Uses process.start (no visible CMD window on Windows). Requires git in PATH.
local core    = require "core"
local common  = require "core.common"
local command = require "core.command"
local style   = require "core.style"
local config  = require "core.config"
local DocView = require "core.docview"

config.plugins.gitgutter = common.merge({
  scan_interval  = 2000,   -- ms between rescans per document
  branch_interval = 15,    -- seconds between branch re-checks
  color_added    = { 80,  200, 100, 255 },
  color_modified = { 230, 180,  50, 255 },
  color_deleted  = { 220,  60,  60, 255 },
}, config.plugins.gitgutter)

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local doc_hunks = setmetatable({}, { __mode = "k" })  -- doc → {added,modified,deleted}
local doc_timer = setmetatable({}, { __mode = "k" })  -- doc → last scan time

local branch_cache = {}   -- proj_dir → branch string (or false = not a git repo)
local branch_timers = {}  -- proj_dir → last check time

local git_ok   = nil      -- nil = unchecked, true/false = cached result
local git_checking = false

---------------------------------------------------------------------------
-- Async git runner — uses process.start, no visible CMD window
---------------------------------------------------------------------------
local function git_async(args, cwd, on_done)
  -- on_done(output_string) called when process exits
  core.add_thread(function()
    local cmd = { "git", "-C", cwd }
    for _, a in ipairs(args) do table.insert(cmd, a) end

    local ok, proc = pcall(process.start, cmd, {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_DISCARD,
    })
    if not ok or not proc then on_done(""); return end

    local chunks = {}
    while proc:running() do
      local chunk = proc:read_stdout(4096)
      if chunk and #chunk > 0 then
        table.insert(chunks, chunk)
      else
        coroutine.yield()
      end
    end
    -- drain remaining output after process exits
    while true do
      local chunk = proc:read_stdout(4096)
      if not chunk or #chunk == 0 then break end
      table.insert(chunks, chunk)
    end
    on_done(table.concat(chunks))
  end)
end

---------------------------------------------------------------------------
-- git_available: async check, returns last known result (default true)
-- to avoid blocking the draw loop on first call
---------------------------------------------------------------------------
local function git_available()
  if git_ok ~= nil then return git_ok end
  -- Return true optimistically; if git isn't found the diff will just be empty
  if not git_checking then
    git_checking = true
    git_async({ "--version" }, ".", function(out)
      git_ok = out:find("git version") ~= nil
      git_checking = false
      core.redraw = true
    end)
  end
  return true  -- optimistic until we know
end

---------------------------------------------------------------------------
-- Parse unified diff (--unified=0)
-- Returns { added = {line→true}, modified = {line→true}, deleted = {line→true} }
---------------------------------------------------------------------------
local function parse_diff(diff_text)
  local result = { added = {}, modified = {}, deleted = {} }
  for line in diff_text:gmatch("[^\n]+") do
    local ns, nc_plus, oc, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if ns then
      local old_c = tonumber(nc_plus) or 1
      local new_s = tonumber(oc)      or 0
      local new_c = tonumber(nc)      or 1
      if old_c == 0 and new_c > 0 then
        for i = new_s, new_s + new_c - 1 do result.added[i] = true end
      elseif new_c == 0 and old_c > 0 then
        result.deleted[math.max(1, new_s)] = true
      else
        for i = new_s, new_s + new_c - 1 do result.modified[i] = true end
      end
    end
  end
  return result
end

---------------------------------------------------------------------------
-- Diff runner
---------------------------------------------------------------------------
local function run_diff(doc)
  local path = doc.abs_filename or doc.filename
  if not path then doc_hunks[doc] = { added={}, modified={}, deleted={} }; return end
  local dir  = common.dirname(path)
  local file = common.basename(path)
  git_async({ "diff", "--unified=0", "HEAD", "--", file }, dir, function(out)
    doc_hunks[doc] = parse_diff(out)
    core.redraw = true
  end)
end

local function schedule_diff(doc)
  if git_ok == false then return end  -- git not available
  local now  = system.get_time()
  local last = doc_timer[doc] or 0
  if now - last < config.plugins.gitgutter.scan_interval / 1000 then return end
  doc_timer[doc] = now
  run_diff(doc)
end

---------------------------------------------------------------------------
-- Branch name — async, returns last cached value immediately
---------------------------------------------------------------------------
local branch_running = {}  -- proj → true while async fetch is in progress

local function get_branch()
  local proj = core.project_directories
    and #core.project_directories > 0
    and core.project_directories[1].name or nil
  if not proj then return nil end

  local now    = system.get_time()
  local last_t = branch_timers[proj] or 0

  -- Return cached value (may be false/nil = not a git repo) within interval
  if branch_cache[proj] ~= nil or (now - last_t < config.plugins.gitgutter.branch_interval) then
    return branch_cache[proj] or nil  -- false → nil for callers
  end

  -- Kick off async fetch if not already running
  if not branch_running[proj] then
    branch_running[proj] = true
    branch_timers[proj]  = now
    git_async({ "rev-parse", "--abbrev-ref", "HEAD" }, proj, function(out)
      out = out:gsub("%s+$", "")
      if out == "" or out:find("^fatal") or out:find("^error") then
        branch_cache[proj] = false  -- not a git repo / no commits yet
      else
        branch_cache[proj] = out
      end
      branch_running[proj] = false
      core.redraw = true
    end)
  end

  return nil  -- not yet known
end

---------------------------------------------------------------------------
-- Override DocView:draw_line_gutter
---------------------------------------------------------------------------
local draw_line_gutter_orig = DocView.draw_line_gutter

function DocView:draw_line_gutter(line, x, y, width)
  local lh = draw_line_gutter_orig(self, line, x, y, width)

  if self.doc then schedule_diff(self.doc) end

  local hunks = self.doc and doc_hunks[self.doc]
  if not hunks then return lh end

  local cfg   = config.plugins.gitgutter
  local bar_w = 2
  local bar_x = x + width - bar_w - 1

  if hunks.added[line] then
    renderer.draw_rect(bar_x, y, bar_w, lh, cfg.color_added)
  elseif hunks.modified[line] then
    renderer.draw_rect(bar_x, y, bar_w, lh, cfg.color_modified)
  elseif hunks.deleted[line] then
    renderer.draw_rect(bar_x, y, bar_w, 2, cfg.color_deleted)
  end

  return lh
end

---------------------------------------------------------------------------
-- Rescan on focus change
---------------------------------------------------------------------------
local set_active_view_orig = core.set_active_view
function core.set_active_view(view)
  set_active_view_orig(view)
  if view and view.doc then
    doc_timer[view.doc] = nil
    schedule_diff(view.doc)
  end
end

---------------------------------------------------------------------------
-- Status bar: branch name
---------------------------------------------------------------------------
local StatusView = require "core.statusview"

core.status_view:add_item({
  name      = "gitgutter:branch",
  alignment = StatusView.Item.LEFT,
  get_item  = function()
    local branch = get_branch()
    if not branch then return {} end
    local accent = style.accent or style.caret or style.text
    return { accent, " \xEF\x84\xA6 " .. branch .. " " }
  end,
  predicate = function()
    -- Only show if we have a confirmed branch (avoid calling get_branch every frame
    -- before async result arrives)
    local proj = core.project_directories
      and #core.project_directories > 0
      and core.project_directories[1].name or nil
    if not proj then return false end
    local b = branch_cache[proj]
    return type(b) == "string"
  end,
})

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
command.add(nil, {
  ["git:refresh-diff"] = function()
    local av = core.active_view
    if av and av.doc then
      doc_timer[av.doc] = nil
      run_diff(av.doc)
    end
  end,
})

return {}
