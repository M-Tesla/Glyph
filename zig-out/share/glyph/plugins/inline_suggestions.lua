-- mod-version:3
-- inline_suggestions.lua — Copilot-like ghost text completions via Claude
-- Trigger: Ctrl+I in any DocView
-- Accept:  Tab (appends ghost text at cursor)
-- Dismiss: Escape or any other edit

local core    = require "core"
local common  = require "core.common"
local style   = require "core.style"
local command = require "core.command"
local keymap  = require "core.keymap"
local DocView = require "core.docview"
local config  = require "core.config"

config.plugins.inline_suggestions = common.merge({
  context_lines_before = 40,
  context_lines_after  = 10,
  model = "haiku",
}, config.plugins.inline_suggestions)

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local ghost   = nil    -- { doc, line, col, text } or nil
local loading = false
local active_proc = nil  -- running process (so we can cancel)

---------------------------------------------------------------------------
-- Find claude.exe (same logic as aichat.lua, cached)
---------------------------------------------------------------------------
local claude_exe = nil

local IS_WIN = PLATFORM == "Windows"

local function find_claude()
  -- Check aichat plugin's cached value first
  local ok, aichat = pcall(require, "plugins.aichat")
  if ok and aichat and aichat.claude_exe then return aichat.claude_exe end

  local exe_name = IS_WIN and "claude.exe" or "claude"
  local plat_seg = IS_WIN and "win32" or "linux"
  local home     = os.getenv("USERPROFILE") or os.getenv("HOME") or ""

  -- Scan extension dirs from several known IDEs
  local ide_ext_dirs = {
    home .. PATHSEP .. ".vscode"          .. PATHSEP .. "extensions",
    home .. PATHSEP .. ".cursor"          .. PATHSEP .. "extensions",
    home .. PATHSEP .. ".vscode-insiders" .. PATHSEP .. "extensions",
    home .. PATHSEP .. ".windsurf"        .. PATHSEP .. "extensions",
  }
  for _, ext_dir in ipairs(ide_ext_dirs) do
    local ok2, entries = pcall(system.list_dir, ext_dir)
    if ok2 and entries then
      table.sort(entries, function(a, b) return a > b end)  -- newest first
      for _, entry in ipairs(entries) do
        if entry:match("^anthropic%.claude%-code") and entry:find(plat_seg) then
          local candidate = ext_dir .. PATHSEP .. entry
            .. PATHSEP .. "resources" .. PATHSEP .. "native-binary" .. PATHSEP .. exe_name
          local info = system.get_file_info(candidate)
          if info and info.type == "file" then return candidate end
        end
      end
    end
  end

  -- Fallback: standalone install (npm -g or direct download) in PATH
  local which_cmd = IS_WIN and "where claude.exe 2>nul" or "which claude 2>/dev/null"
  local p = io.popen(which_cmd)
  if p then
    local out = p:read("*l"); p:close()
    if out and out ~= "" then return out:match("^%s*(.-)%s*$") end
  end
  return nil
end

---------------------------------------------------------------------------
-- Clear state
---------------------------------------------------------------------------
local function clear_ghost()
  ghost = nil
  loading = false
  if active_proc then
    pcall(function() active_proc:terminate() end)
    active_proc = nil
  end
  core.redraw = true
end

---------------------------------------------------------------------------
-- Request suggestion — uses process.start, non-blocking coroutine
---------------------------------------------------------------------------
local function request_suggestion(doc, line, col)
  if not claude_exe then claude_exe = find_claude() end
  if not claude_exe then
    core.log("Inline suggestions: claude.exe not found")
    loading = false
    return
  end

  -- Collect context lines
  local before_start = math.max(1, line - config.plugins.inline_suggestions.context_lines_before)
  local after_end    = math.min(#doc.lines, line + config.plugins.inline_suggestions.context_lines_after)

  local before = {}
  for i = before_start, line do
    local l = (doc.lines[i] or ""):gsub("\n", "")
    if i == line then l = l:sub(1, col - 1) end
    table.insert(before, l)
  end
  local after = {}
  for i = line + 1, after_end do
    table.insert(after, (doc.lines[i] or ""):gsub("\n", ""))
  end

  local prompt = "Complete the code at the cursor. Return ONLY the completion"
    .. " (what comes right after the cursor). No explanation, no markdown, no fences."
    .. " One expression or statement max.\n\n"
    .. "File: " .. (doc.filename or "untitled") .. "\n\n"
    .. "[BEFORE CURSOR]\n" .. table.concat(before, "\n") .. "\n"
    .. "[CURSOR]\n"
    .. "[AFTER CURSOR]\n" .. table.concat(after, "\n")

  local model = config.plugins.inline_suggestions.model

  core.add_thread(function()
    -- Start claude process with stdin pipe
    local ok, proc = pcall(process.start,
      { claude_exe, "-p", "--model", model },
      { stderr = process.REDIRECT_DISCARD }
    )
    if not ok or not proc then
      loading = false
      core.log("Inline suggestions: failed to start claude")
      return
    end

    active_proc = proc

    -- Send prompt via stdin then close it
    proc:write(prompt)
    proc:close_stream(0)  -- 0 = STDIN_FD — signals EOF to claude

    -- Read stdout non-blocking, yield between chunks
    local chunks = {}
    local timeout = system.get_time() + 30  -- 30s timeout

    while proc:running() do
      if system.get_time() > timeout then
        proc:terminate()
        break
      end
      local chunk = proc:read_stdout(4096)
      if chunk and #chunk > 0 then
        table.insert(chunks, chunk)
      else
        coroutine.yield()
      end
    end

    -- Drain any remaining output
    while true do
      local chunk = proc:read_stdout(4096)
      if not chunk or #chunk == 0 then break end
      table.insert(chunks, chunk)
    end

    active_proc = nil

    -- Only apply if the doc/position hasn't changed
    if not loading then return end  -- cancelled

    local result = table.concat(chunks):match("^%s*(.-)%s*$") or ""

    -- Reject error output
    if result == "" or result:find("^Error") or result:find("^fatal") or result:find("^Usage:") then
      loading = false
      core.redraw = true
      return
    end

    -- Take only the first line for inline display
    local first_line = result:match("^([^\n]+)") or result
    first_line = first_line:match("^%s*(.-)%s*$")

    if first_line ~= "" then
      ghost = { doc = doc, line = line, col = col, text = first_line }
    end
    loading = false
    core.redraw = true
  end)
end

---------------------------------------------------------------------------
-- Draw ghost text
---------------------------------------------------------------------------
local draw_line_text_orig = DocView.draw_line_text

function DocView:draw_line_text(idx, x, y)
  local lh = draw_line_text_orig(self, idx, x, y)

  if ghost and ghost.doc == self.doc and ghost.line == idx then
    local prefix = (self.doc.lines[idx] or ""):sub(1, ghost.col - 1):gsub("\n", "")
    local gx = x + style.code_font:get_width(prefix)
    local gc = style.dim
    renderer.draw_text(style.code_font, ghost.text, gx, y, { gc[1], gc[2], gc[3], 150 })
  end

  return lh
end

---------------------------------------------------------------------------
-- Clear ghost on any edit
---------------------------------------------------------------------------
local on_text_input_orig = DocView.on_text_input
function DocView:on_text_input(text)
  if ghost and ghost.doc == self.doc then clear_ghost() end
  return on_text_input_orig(self, text)
end

---------------------------------------------------------------------------
-- Tab / Escape intercept
---------------------------------------------------------------------------
local on_key_pressed_orig = DocView.on_key_pressed
function DocView:on_key_pressed(key, ...)
  if ghost and ghost.doc == self.doc then
    if key == "tab" then
      -- Accept: insert ghost text at cursor position
      local line, col = self.doc:get_selection()
      if line == ghost.line and col == ghost.col then
        self.doc:insert(line, col, ghost.text)
        self.doc:set_selection(line, col + #ghost.text)
      end
      clear_ghost()
      return true
    elseif key == "escape" then
      clear_ghost()
      return true
    end
  end
  -- Also clear ghost on cursor movement keys
  if ghost and ghost.doc == self.doc then
    local nav = { up=1, down=1, left=1, right=1, home=1, ["end"]=1, pageup=1, pagedown=1 }
    if nav[key] then clear_ghost() end
  end
  return on_key_pressed_orig(self, key, ...)
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
command.add("core.docview", {
  ["inline-suggestions:trigger"] = function()
    local view = core.active_view
    if not view or not view.doc then return end

    clear_ghost()  -- cancel any pending

    local line, col = view.doc:get_selection()
    loading = true
    core.redraw = true
    core.log("Getting suggestion...")
    request_suggestion(view.doc, line, col)
  end,

  ["inline-suggestions:dismiss"] = function()
    clear_ghost()
  end,
})

keymap.add {
  ["ctrl+i"] = "inline-suggestions:trigger",
}

---------------------------------------------------------------------------
-- Status bar indicator
---------------------------------------------------------------------------
local StatusView = require "core.statusview"
core.status_view:add_item({
  name      = "inline-suggestions:status",
  alignment = StatusView.Item.RIGHT,
  get_item  = function()
    if loading then
      return { style.dim, "  thinking... " }
    elseif ghost then
      return { style.dim, "  Tab to accept " }
    end
    return {}
  end,
  predicate = function() return loading or ghost ~= nil end,
})

return {}
