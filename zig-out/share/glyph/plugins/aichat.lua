-- mod-version:3 -- priority:110
-- AI Chat plugin for Glyph — agents, knowledge, claude.exe CLI
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local DocView = require "core.docview"

config.plugins.aichat = common.merge({
  size = 340 * SCALE,
  model = "sonnet",
  max_knowledge_size = 100 * 1024,  -- 100KB total knowledge cap
}, config.plugins.aichat)

-- Forward declarations (needed before function definitions that reference them)
local chat_view  -- assigned later after AIChatView class is created
global { glyph_ai_send = false }  -- declared early so selection_actions.lua can safely check it


---------------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------------
local log_path = USERDIR .. PATHSEP .. "aichat.log"
local function log(msg)
  local f = io.open(log_path, "a")
  if f then f:write(os.date() .. " " .. msg .. "\n"); f:close() end
end
log("aichat.lua loading")


---------------------------------------------------------------------------
-- Find claude.exe
---------------------------------------------------------------------------
local claude_exe = nil
local IS_WIN = PLATFORM == "Windows"

local function find_claude_exe()
  local exe_name = IS_WIN and "claude.exe" or "claude"
  local plat_seg = IS_WIN and "win32"       or "linux"
  local home     = os.getenv("USERPROFILE") or os.getenv("HOME") or ""

  -- Search extension directories from several known IDEs in priority order.
  -- Any of them may bundle the Claude Code CLI.
  local ide_ext_dirs = {
    home .. PATHSEP .. ".vscode"          .. PATHSEP .. "extensions",  -- VS Code
    home .. PATHSEP .. ".cursor"          .. PATHSEP .. "extensions",  -- Cursor
    home .. PATHSEP .. ".vscode-insiders" .. PATHSEP .. "extensions",  -- VS Code Insiders
    home .. PATHSEP .. ".windsurf"        .. PATHSEP .. "extensions",  -- Windsurf
  }

  for _, ext_dir in ipairs(ide_ext_dirs) do
    local ok, entries = pcall(system.list_dir, ext_dir)
    if ok and entries then
      local best_path, best_ver = nil, ""
      for _, entry in ipairs(entries) do
        if entry:match("^anthropic%.claude%-code%-") then
          local ver = entry:match("anthropic%.claude%-code%-(.-)-" .. plat_seg)
          if ver and ver > best_ver then
            local candidate = ext_dir .. PATHSEP .. entry .. PATHSEP
              .. "resources" .. PATHSEP .. "native-binary" .. PATHSEP .. exe_name
            local info = system.get_file_info(candidate)
            if info and info.type == "file" then
              best_path = candidate
              best_ver  = ver
            end
          end
        end
      end
      if best_path then return best_path end
    end
  end

  -- Fallback: standalone install via npm (-g) or direct download — just needs to be in PATH
  local which_cmd = IS_WIN and "where claude.exe 2>nul" or "which claude 2>/dev/null"
  local p = io.popen(which_cmd)
  if p then
    local out = p:read("*l"); p:close()
    if out and out ~= "" then return out:match("^%s*(.-)%s*$") end
  end
  return nil
end

local function ensure_claude_exe()
  if not claude_exe then claude_exe = find_claude_exe() end
  return claude_exe
end


---------------------------------------------------------------------------
-- Auth
---------------------------------------------------------------------------
local auth_info = nil
local auth_checked = false

local function check_auth_status()
  if auth_checked then return end
  auth_checked = true
  if not ensure_claude_exe() then
    auth_info = { loggedIn = false, error = "claude.exe not found" }
    return
  end
  -- claude writes to console directly (bypasses pipes on Windows),
  -- so redirect output to a temp file via script and read it after.
  local out_file = USERDIR .. PATHSEP .. "claude_auth_result.json"
  local script, proc_cmd
  if IS_WIN then
    script = USERDIR .. PATHSEP .. "claude_auth_check.bat"
    local bf = io.open(script, "w")
    if bf then
      bf:write('@echo off\r\n')
      bf:write('"' .. claude_exe .. '" auth status > "' .. out_file .. '" 2>&1\r\n')
      bf:close()
    end
    proc_cmd = { "cmd.exe", "/c", script }
  else
    script = USERDIR .. PATHSEP .. "claude_auth_check.sh"
    local bf = io.open(script, "w")
    if bf then
      bf:write('#!/bin/sh\n')
      bf:write('"' .. claude_exe .. '" auth status > "' .. out_file .. '" 2>&1\n')
      bf:close()
    end
    os.execute('chmod +x "' .. script .. '"')
    proc_cmd = { "/bin/sh", script }
  end
  local proc = process.start(proc_cmd, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE })
  if not proc then
    auth_info = { loggedIn = false, error = "Failed to check auth" }
    return
  end
  core.add_thread(function()
    while proc:returncode() == nil do
      proc:read_stdout(4096)
      coroutine.yield()
    end
    local buf = ""
    local rf = io.open(out_file, "r")
    if rf then
      buf = rf:read("*a") or ""
      rf:close()
    end
    log("auth: " .. (buf:match('"loggedIn"%s*:%s*(%w+)') or "?"))
    if buf == "" then
      auth_info = { loggedIn = false, error = "No output from auth status" }
    else
      auth_info = {
        loggedIn = buf:match('"loggedIn"%s*:%s*(true)') ~= nil,
        email = buf:match('"email"%s*:%s*"([^"]*)"'),
        subscriptionType = buf:match('"subscriptionType"%s*:%s*"([^"]*)"'),
        authMethod = buf:match('"authMethod"%s*:%s*"([^"]*)"'),
      }
    end
    core.redraw = true
  end)
end

local function do_login()
  if not ensure_claude_exe() then core.error("claude.exe not found"); return end
  if PLATFORM == "Windows" then
    -- Write a temp .bat that clears CLAUDECODE and runs login, keeps window open on error
    local bat = USERDIR .. PATHSEP .. "claude_login.bat"
    local f = io.open(bat, "w")
    if f then
      f:write('@echo off\r\n')
      f:write('set CLAUDECODE=\r\n')
      f:write('"' .. claude_exe .. '" auth login\r\n')
      f:write('echo.\r\n')
      f:write('echo Login complete. You can close this window.\r\n')
      f:write('pause\r\n')
      f:close()
      os.execute('start "Claude Login" "' .. bat .. '"')
    end
  else
    os.execute('CLAUDECODE="" "' .. claude_exe .. '" auth login &')
  end
  core.log("AI: Login window opened — complete login, then click Refresh.")
  core.add_thread(function()
    local t = os.time()
    while os.time() - t < 5 do coroutine.yield() end
    auth_checked = false; auth_info = nil
    check_auth_status()
  end)
end


---------------------------------------------------------------------------
-- Agents (declared early so persistence functions can reference them)
---------------------------------------------------------------------------
local agents = {}
local active_agent_idx = 1
local agent_counter = 0


---------------------------------------------------------------------------
-- Persistence (Lua table serializer)
---------------------------------------------------------------------------
local history_path = USERDIR .. PATHSEP .. "aichat_history.lua"

local function serialize_value(v, indent)
  local t = type(v)
  if t == "string" then
    return string.format("%q", v)
  elseif t == "number" or t == "boolean" then
    return tostring(v)
  elseif t == "nil" then
    return "nil"
  elseif t == "table" then
    local parts = {}
    local ind = indent or ""
    local ind2 = ind .. "  "
    -- Check if array-like
    local is_array = #v > 0
    if is_array then
      for i, val in ipairs(v) do
        parts[i] = ind2 .. serialize_value(val, ind2)
      end
    else
      for k, val in pairs(v) do
        if type(k) == "string" then
          parts[#parts + 1] = ind2 .. k .. " = " .. serialize_value(val, ind2)
        end
      end
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "}"
  end
  return "nil"
end

local function save_history()
  local data = {
    agents = {},
    active_agent_idx = active_agent_idx,
    agent_counter = agent_counter,
  }
  for _, agent in ipairs(agents) do
    table.insert(data.agents, {
      name = agent.name,
      instructions = agent.instructions,
      session_id = agent.session_id,
      created = agent.created,
      messages = agent.messages,
    })
  end
  local f = io.open(history_path, "w")
  if f then
    f:write("return " .. serialize_value(data, "") .. "\n")
    f:close()
  end
end

local function load_history()
  local ok, data = pcall(dofile, history_path)
  if ok and data and data.agents and #data.agents > 0 then
    agents = {}
    for _, a in ipairs(data.agents) do
      table.insert(agents, {
        name = a.name or "Chat",
        instructions = a.instructions or "",
        messages = a.messages or {},
        session_id = a.session_id,
        status = "idle",
        created = a.created or os.time(),
      })
    end
    active_agent_idx = data.active_agent_idx or 1
    agent_counter = data.agent_counter or #agents
    if active_agent_idx > #agents then active_agent_idx = 1 end
    log("loaded " .. #agents .. " agents from history")
    return true
  end
  return false
end


---------------------------------------------------------------------------
-- Agent functions
---------------------------------------------------------------------------
local function create_agent(name, instructions)
  agent_counter = agent_counter + 1
  if not name or name == "" then name = "Agent " .. agent_counter end
  local agent = {
    name = name,
    instructions = instructions or "",
    messages = {},
    session_id = nil,
    status = "idle",
    created = os.time(),
  }
  table.insert(agents, agent)
  save_history()
  return agent, #agents
end

local function get_active_agent()
  if #agents == 0 then create_agent("Chat") end
  if active_agent_idx < 1 or active_agent_idx > #agents then
    active_agent_idx = 1
  end
  return agents[active_agent_idx]
end

local function set_active_agent(idx)
  if idx >= 1 and idx <= #agents then
    active_agent_idx = idx
    save_history()
  end
end

local function delete_agent(idx)
  if #agents <= 1 then return end
  table.remove(agents, idx)
  if active_agent_idx > #agents then active_agent_idx = #agents end
  if active_agent_idx < 1 then active_agent_idx = 1 end
  save_history()
end

local function add_message(agent, role, text)
  table.insert(agent.messages, { role = role, text = text, timestamp = os.time() })
  save_history()
  if chat_view then chat_view.should_scroll_bottom = true end
  return agent.messages[#agent.messages]
end

-- Load history or create default agent
if not load_history() then
  create_agent("Chat")
end


---------------------------------------------------------------------------
-- Knowledge
---------------------------------------------------------------------------
local knowledge_files = {}
local knowledge_scanned = false
local knowledge_last_proj = nil  -- tracks project dir at last scan
local knowledge_dir_exists = false  -- folder detected even if empty

local function scan_knowledge()
  knowledge_files = {}
  knowledge_dir_exists = false
  local cur_proj = (core.project_directories and #core.project_directories > 0)
    and core.project_directories[1].name or nil
  knowledge_last_proj = cur_proj
  -- Project knowledge/
  if cur_proj then
    local kdir = cur_proj .. PATHSEP .. "knowledge"
    local dir_info = system.get_file_info(kdir)
    if dir_info and dir_info.type == "dir" then
      knowledge_dir_exists = true
      local ok, entries = pcall(system.list_dir, kdir)
      if ok and entries then
        for _, entry in ipairs(entries) do
          local path = kdir .. PATHSEP .. entry
          local info = system.get_file_info(path)
          if info and info.type == "file" then
            table.insert(knowledge_files, {
              path = path, name = entry, size = info.size,
              enabled = true, source = "project",
            })
          end
        end
      end
    end
  end
  -- Global USERDIR/knowledge/
  local udir = USERDIR .. PATHSEP .. "knowledge"
  local udir_info = system.get_file_info(udir)
  if udir_info and udir_info.type == "dir" then
    knowledge_dir_exists = true
    local ok2, entries2 = pcall(system.list_dir, udir)
    if ok2 and entries2 then
      for _, entry in ipairs(entries2) do
        local path = udir .. PATHSEP .. entry
        local info = system.get_file_info(path)
        if info and info.type == "file" then
          table.insert(knowledge_files, {
            path = path, name = entry, size = info.size,
            enabled = true, source = "global",
          })
        end
      end
    end
  end
  knowledge_scanned = true
  log("scan_knowledge: proj=" .. (cur_proj or "nil") .. " dir_exists=" .. tostring(knowledge_dir_exists) .. " files=" .. #knowledge_files)
end

local function get_knowledge_context()
  local parts = {}
  local total = 0
  local cap = config.plugins.aichat.max_knowledge_size
  for _, kf in ipairs(knowledge_files) do
    if kf.enabled and total < cap then
      local f = io.open(kf.path, "r")
      if f then
        local content = f:read("*a")
        f:close()
        if content and #content > 0 then
          if total + #content > cap then
            content = content:sub(1, cap - total) .. "\n[...truncated]"
          end
          total = total + #content
          table.insert(parts, "--- " .. kf.name .. " ---\n" .. content)
        end
      end
    end
  end
  if #parts == 0 then return "" end
  return "[Knowledge]\n" .. table.concat(parts, "\n\n") .. "\n\n"
end

local function create_knowledge_folder()
  if not core.project_directories or #core.project_directories == 0 then return false end
  local kdir = core.project_directories[1].name .. PATHSEP .. "knowledge"
  local ok = pcall(system.mkdir, kdir)
  if ok then
    scan_knowledge()
    core.log("Created knowledge/ folder")
  end
  return ok
end

local function format_size(bytes)
  if bytes < 1024 then return bytes .. " B" end
  if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
  return string.format("%.1f MB", bytes / (1024 * 1024))
end


---------------------------------------------------------------------------
-- EKS — Enterprise Knowledge System (.glyph/ hierarchy)
---------------------------------------------------------------------------
local eks_files = {}    -- { path, name, label, size, enabled, source, layer }
local eks_scanned = false
local eks_last_proj = nil  -- tracks project dir at last scan

-- Ordered EKS files by layer priority (injected in this order)
local EKS_LAYERS = {
  { file = "company.md",   label = "Company"   },
  { file = "domain.md",    label = "Domain"    },
  { file = "standards.md", label = "Standards" },
  { file = "team.md",      label = "Team"      },
}

local function scan_eks_dir(dir, source_tag)
  local results = {}
  -- Main .glyph/ files (ordered by EKS_LAYERS first)
  for _, layer in ipairs(EKS_LAYERS) do
    local path = dir .. PATHSEP .. layer.file
    local info = system.get_file_info(path)
    if info and info.type == "file" then
      table.insert(results, {
        path = path, name = layer.file, label = layer.label,
        size = info.size, enabled = true,
        source = source_tag, layer = "core",
        last_mtime = info.modified,
      })
    end
  end
  -- adr/ subfolder
  local adr_dir = dir .. PATHSEP .. "adr"
  local ok, entries = pcall(system.list_dir, adr_dir)
  if ok and entries then
    table.sort(entries)
    for _, entry in ipairs(entries) do
      if entry:match("%.md$") then
        local path = adr_dir .. PATHSEP .. entry
        local info = system.get_file_info(path)
        if info and info.type == "file" then
          table.insert(results, {
            path = path, name = entry, label = "ADR",
            size = info.size, enabled = true,
            source = source_tag, layer = "adr",
            last_mtime = info.modified,
          })
        end
      end
    end
  end
  return results
end

local function scan_eks()
  eks_files = {}
  local cur_proj = (core.project_directories and #core.project_directories > 0)
    and core.project_directories[1].name or nil
  eks_last_proj = cur_proj
  -- Global: ~/.glyph/
  local home = os.getenv("USERPROFILE") or os.getenv("HOME") or ""
  if home ~= "" then
    local global_dir = home .. PATHSEP .. ".glyph"
    local info = system.get_file_info(global_dir)
    if info and info.type == "dir" then
      for _, f in ipairs(scan_eks_dir(global_dir, "global")) do
        table.insert(eks_files, f)
      end
    end
  end
  -- Project: <project>/.glyph/
  if cur_proj then
    local proj_dir = cur_proj .. PATHSEP .. ".glyph"
    local info = system.get_file_info(proj_dir)
    if info and info.type == "dir" then
      for _, f in ipairs(scan_eks_dir(proj_dir, "project")) do
        table.insert(eks_files, f)
      end
    end
  end
  eks_scanned = true
  log("scan_eks: proj=" .. (cur_proj or "nil") .. " found=" .. #eks_files .. " files")
end

---------------------------------------------------------------------------
-- Project file list (for @mention autocomplete)
---------------------------------------------------------------------------
local project_files_cache = nil
local project_files_proj  = nil

local MENTION_SKIP = {
  ["zig-out"] = true, [".zig-cache"] = true, ["zig-cache"] = true,
  ["node_modules"] = true, [".git"] = true, [".glyph"] = true,
}
local MENTION_EXT = {
  lua=true, zig=true, md=true, txt=true, json=true, toml=true,
  c=true, h=true, cpp=true, hpp=true, py=true, js=true, ts=true,
  go=true, rs=true, rb=true, sh=true, yaml=true, yml=true,
}

local function get_project_files()
  local cur_proj = core.project_directories and #core.project_directories > 0
    and core.project_directories[1].name or nil
  if project_files_cache and project_files_proj == cur_proj then
    return project_files_cache
  end
  local files = {}
  local function scan(dir, rel, depth)
    if depth > 4 then return end
    local ok, entries = pcall(system.list_dir, dir)
    if not ok or not entries then return end
    for _, e in ipairs(entries) do
      if not e:match("^%.") or e:match("%.md$") or e:match("%.txt$") then
        if not MENTION_SKIP[e] then
          local full = dir .. PATHSEP .. e
          local rel_e = rel and (rel .. "/" .. e) or e
          local info = system.get_file_info(full)
          if info then
            if info.type == "file" then
              local ext = e:match("%.([^%.]+)$")
              if ext and MENTION_EXT[ext:lower()] then
                table.insert(files, { name = e, rel = rel_e, full = full })
              end
            elseif info.type == "dir" and not MENTION_SKIP[e] then
              scan(full, rel_e, depth + 1)
            end
          end
        end
      end
    end
  end
  if cur_proj then scan(cur_proj, nil, 0) end
  project_files_cache = files
  project_files_proj  = cur_proj
  return files
end

local function get_eks_context()
  if #eks_files == 0 then return "" end
  local parts = {}
  local total = 0
  local cap = config.plugins.aichat.max_knowledge_size
  for _, ef in ipairs(eks_files) do
    if ef.enabled and total < cap then
      local f = io.open(ef.path, "r")
      if f then
        local content = f:read("*a")
        f:close()
        if content and #content > 0 then
          if total + #content > cap then
            content = content:sub(1, cap - total) .. "\n[...truncated]"
          end
          total = total + #content
          table.insert(parts, "### " .. ef.label .. " (" .. ef.name .. ")\n" .. content)
        end
      end
    end
  end
  if #parts == 0 then return "" end
  return "[Enterprise Context]\n" .. table.concat(parts, "\n\n") .. "\n\n"
end

-- Creates .glyph/ structure with template files in the current project
local EKS_TEMPLATES = {
  ["company.md"] = [[# Company

**Name:** <!-- Your company name -->
**Domain:** <!-- e.g. B2B SaaS, E-commerce, Fintech -->
**Mission:** <!-- One-liner mission statement -->

## Tech Stack
- <!-- e.g. Node.js, PostgreSQL, AWS -->

## Key Systems
- <!-- List main internal systems/services -->
]],
  ["domain.md"] = [[# Domain Model

## Core Entities
<!-- Define your main business entities -->

### Example Entity
- **Description:** what it represents
- **Key attributes:** id, name, status, ...
- **Relations:** belongs to X, has many Y

## Glossary
| Term | Definition |
|------|-----------|
| <!-- term --> | <!-- definition --> |
]],
  ["standards.md"] = [[# Engineering Standards

## Code Style
- <!-- e.g. 2 spaces indent, single quotes -->

## API Design
- <!-- e.g. REST, versioned at /api/v1, JSON -->

## Naming Conventions
- Files: <!-- e.g. kebab-case -->
- Variables: <!-- e.g. camelCase -->
- Database: <!-- e.g. snake_case -->

## Testing
- <!-- e.g. unit tests required for all business logic -->
]],
  ["team.md"] = [[# Team & Ownership

## Structure
- <!-- e.g. Team Payments: owns billing/, payments/ -->
- <!-- e.g. Team Platform: owns infra/, core/ -->

## Module Owners
| Module | Owner | Contact |
|--------|-------|---------|
| <!-- path --> | <!-- name --> | <!-- @handle --> |

## Review Policy
- <!-- e.g. 2 approvals required for main branch -->
]],
}

local function create_glyph_structure()
  if not core.project_directories or #core.project_directories == 0 then
    core.error("No project open"); return false
  end
  local glyph_dir = core.project_directories[1].name .. PATHSEP .. ".glyph"
  local adr_dir = glyph_dir .. PATHSEP .. "adr"
  pcall(system.mkdir, glyph_dir)
  pcall(system.mkdir, adr_dir)
  for filename, content in pairs(EKS_TEMPLATES) do
    local path = glyph_dir .. PATHSEP .. filename
    local info = system.get_file_info(path)
    if not info then  -- don't overwrite existing files
      local f = io.open(path, "w")
      if f then f:write(content); f:close() end
    end
  end
  -- Create .gitkeep in adr/
  local gk = io.open(adr_dir .. PATHSEP .. ".gitkeep", "w")
  if gk then gk:write(""); gk:close() end
  eks_scanned = false
  scan_eks()
  core.log("Created .glyph/ structure with templates")
  return true
end


---------------------------------------------------------------------------
-- Context
---------------------------------------------------------------------------
local function get_active_file_context()
  local view = core.active_view
  if not view or not view:is(DocView) then return nil end
  local doc = view.doc
  if not doc or not doc.filename then return nil end
  local rel = doc.filename
  if core.project_directories and #core.project_directories > 0 then
    local pdir = core.project_directories[1].name
    if rel:sub(1, #pdir) == pdir then rel = rel:sub(#pdir + 2) end
  end
  return { filename = rel, full_path = doc.filename, line_count = #doc.lines }
end

local function get_selection_context()
  local view = core.active_view
  if not view or not view:is(DocView) then return nil end
  local doc = view.doc
  if not doc then return nil end
  local l1, c1, l2, c2 = doc:get_selection()
  if l1 == l2 and c1 == c2 then return nil end
  return { text = doc:get_text(l1, c1, l2, c2), line1 = l1, col1 = c1, line2 = l2, col2 = c2 }
end

local function build_context_prefix(agent)
  local parts = {}
  -- 1. EKS context (highest priority — company/domain/standards/team/ADRs)
  local eksctx = get_eks_context()
  if eksctx ~= "" then table.insert(parts, eksctx) end
  -- 2. Project knowledge files
  local kctx = get_knowledge_context()
  if kctx ~= "" then table.insert(parts, kctx) end
  -- 3. Agent identity
  if agent and agent.name ~= "Chat" then
    table.insert(parts, "[Agent: " .. agent.name .. "]")
  end
  if agent and agent.instructions and agent.instructions ~= "" then
    table.insert(parts, "[Instructions]\n" .. agent.instructions)
  end
  -- 4. Project name
  if core.project_directories and #core.project_directories > 0 then
    local dir = core.project_directories[1]
    table.insert(parts, "Project: " .. (dir.name:match("[/\\]([^/\\]+)$") or dir.name))
  end
  -- 5. Current file
  local f = get_active_file_context()
  if f then table.insert(parts, "File: " .. f.filename .. " (" .. f.line_count .. " lines)") end
  -- 6. Selection
  local s = get_selection_context()
  if s then table.insert(parts, "Selected (lines " .. s.line1 .. "-" .. s.line2 .. "):\n```\n" .. s.text .. "\n```") end
  if #parts == 0 then return "" end
  return table.concat(parts, "\n") .. "\n\n"
end


---------------------------------------------------------------------------
-- Claude runner
---------------------------------------------------------------------------
local running_proc = nil
local running_agent = nil
local streaming_msg = nil

local function send_to_claude(agent, prompt, on_chunk, on_done)
  log("send_to_claude called, prompt=" .. #prompt .. " bytes")
  if not ensure_claude_exe() then on_done(nil, "claude.exe not found"); return end
  if running_proc then on_done(nil, "Already processing."); return end

  -- Build script that pipes prompt to claude, output goes to a file.
  -- We poll the file for new lines to get streaming effect.
  local out_file    = USERDIR .. PATHSEP .. "claude_stream_output.jsonl"
  local prompt_file = USERDIR .. PATHSEP .. "claude_prompt.txt"
  local script_ext  = IS_WIN and ".bat" or ".sh"
  local script      = USERDIR .. PATHSEP .. "claude_run" .. script_ext

  -- Write prompt to file (avoids shell escaping issues)
  local pf = io.open(prompt_file, "w")
  if not pf then on_done(nil, "Failed to write prompt"); return end
  pf:write(prompt)
  pf:close()

  -- Clear output file
  local of = io.open(out_file, "w")
  if of then of:close() end

  -- Build command string
  local cmd_parts = {
    '"' .. claude_exe .. '" -p',
    '--output-format stream-json --verbose',
    '--model ' .. config.plugins.aichat.model,
    '--allowedTools "Edit" --allowedTools "Write" --allowedTools "Read"',
    '--allowedTools "Bash" --allowedTools "Glob" --allowedTools "Grep"',
  }
  if agent.session_id then
    table.insert(cmd_parts, '--resume ' .. agent.session_id)
  end

  local run_cmd = table.concat(cmd_parts, ' ') .. ' < "' .. prompt_file .. '" > "' .. out_file .. '" 2>&1'
  local bf = io.open(script, "w")
  if not bf then on_done(nil, "Failed to write run script"); return end
  if IS_WIN then
    bf:write('@echo off\r\n')
    bf:write(run_cmd .. '\r\n')
  else
    bf:write('#!/bin/sh\n')
    bf:write(run_cmd .. '\n')
  end
  bf:close()
  log("script written: " .. script)
  log("script cmd: " .. run_cmd)

  local proc_cmd = IS_WIN and { "cmd.exe", "/c", script } or { "/bin/sh", script }
  local proc = process.start(proc_cmd, {
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  if not proc then on_done(nil, "Failed to start claude"); return end
  log("process started")

  running_proc = proc
  running_agent = agent
  agent.status = "running"

  core.add_thread(function()
    local file_pos = 0
    local line_buf = ""
    while true do
      -- Poll output file for new data
      local rf = io.open(out_file, "r")
      if rf then
        rf:seek("set", file_pos)
        local new_data = rf:read("*a")
        rf:close()
        if new_data and #new_data > 0 then
          file_pos = file_pos + #new_data
          line_buf = line_buf .. new_data
          -- Process complete lines
          while true do
            local nl = line_buf:find("\n")
            if not nl then break end
            local line = line_buf:sub(1, nl - 1)
            line_buf = line_buf:sub(nl + 1)
            if line ~= "" then
              local tc = line:match('"text"%s*:%s*"(.-)"')
              if tc then
                tc = tc:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\")
                on_chunk(tc)
              end
              local sid = line:match('"session_id"%s*:%s*"([^"]+)"')
              if sid then agent.session_id = sid end
            end
          end
        end
      end
      -- Check if process is done
      proc:read_stdout(4096)  -- drain pipe
      local rc = proc:returncode()
      if rc ~= nil then
        log("process done, exit=" .. tostring(rc) .. " file_pos=" .. file_pos)
        -- Read any remaining data
        local rf2 = io.open(out_file, "r")
        if rf2 then
          rf2:seek("set", file_pos)
          local remaining = rf2:read("*a")
          rf2:close()
          if remaining and #remaining > 0 then
            for line in (line_buf .. remaining):gmatch("([^\n]+)") do
              local tc = line:match('"text"%s*:%s*"(.-)"')
              if tc then
                tc = tc:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\")
                on_chunk(tc)
              end
              local sid = line:match('"session_id"%s*:%s*"([^"]+)"')
              if sid then agent.session_id = sid end
            end
          end
        end
        running_proc = nil
        running_agent = nil
        agent.status = "idle"
        on_done(rc == 0 and "ok" or nil, rc ~= 0 and ("Exit code " .. rc) or nil)
        return
      end
      coroutine.yield()
    end
  end)
end


---------------------------------------------------------------------------
-- Word wrap helper (for messages display only)
---------------------------------------------------------------------------
local function word_wrap(font, text, max_w)
  if max_w <= 0 then max_w = 100 end
  local lines = {}
  for paragraph in (text .. "\n"):gmatch("(.-)\n") do
    if paragraph == "" then
      table.insert(lines, "")
    else
      local line = ""
      for word in paragraph:gmatch("%S+") do
        local test = line == "" and word or (line .. " " .. word)
        if font:get_width(test) > max_w and line ~= "" then
          table.insert(lines, line)
          line = word
        else
          line = test
        end
      end
      if line ~= "" then table.insert(lines, line) end
    end
  end
  return lines
end

-- Position-aware wrap for the input field.
-- Returns array of { text = "...", cstart = N }
-- cstart is the 0-indexed byte offset in original text where this visual line starts.
-- text is the ACTUAL slice of the original string (preserving spaces for accurate cursor rendering).
-- Non-last visual lines have trailing whitespace trimmed; the last line preserves it so the
-- cursor can visually appear after typed spaces.
local function input_wrap_pos(font, text, max_w)
  if max_w <= 0 then max_w = 100 end
  if text == "" then return {{ text = "", cstart = 0 }} end

  local result = {}
  local pos = 1  -- 1-indexed in text

  while pos <= #text do
    local nl = text:find("\n", pos, true)
    local para_end = nl and (nl - 1) or #text
    local para = text:sub(pos, para_end)
    local pcstart = pos - 1  -- 0-indexed byte offset of paragraph start in text

    if #para == 0 then
      table.insert(result, { text = "", cstart = pcstart })
    else
      local lstart = 1  -- 1-indexed within para: start of current visual line

      while lstart <= #para do
        local scan = lstart
        local last_word_end = nil  -- 1-indexed end of last word that fits on this line
        local did_char_break = false

        while scan <= #para do
          local ws = para:find("%S", scan)
          if not ws then
            -- Only whitespace remains; include it all on this line
            last_word_end = #para
            break
          end
          local wsep = para:find("%s", ws)
          local we = wsep and (wsep - 1) or #para

          -- Measure candidate: from line start to end of this word
          local cw = font:get_width(para:sub(lstart, we))
          if cw > max_w then
            if last_word_end then
              -- Previous word(s) fit; break before this word
              break
            else
              -- Even the first word on this line is too long: character-break
              for ci = lstart, we do
                if font:get_width(para:sub(lstart, ci)) > max_w then
                  local brk = math.max(lstart, ci - 1)
                  table.insert(result, {
                    text   = para:sub(lstart, brk),
                    cstart = pcstart + lstart - 1,
                  })
                  lstart = brk + 1
                  did_char_break = true
                  break
                end
              end
              if not did_char_break then
                -- Word fits after exhausting loop (edge: very wide max_w)
                last_word_end = we
                scan = we + 1
              end
              break
            end
          else
            last_word_end = we
            scan = we + 1
          end
        end

        if not did_char_break then
          local line_end = last_word_end or #para
          -- Use the actual slice from the original paragraph string.
          -- For non-last wrapped lines, trim trailing whitespace (visual line-break artifact).
          -- For the last line, preserve trailing spaces so the cursor renders correctly.
          local line_text = para:sub(lstart, line_end)
          if line_end < #para then
            line_text = line_text:gsub("%s+$", "")
          end
          table.insert(result, {
            text   = line_text,
            cstart = pcstart + lstart - 1,
          })
          if line_end >= #para then break end
          -- Advance past whitespace to the start of the next visual line
          local next = para:find("%S", line_end + 1)
          if not next then break end
          lstart = next
        end
      end
    end

    if not nl then break end
    pos = nl + 1
    if pos > #text then
      table.insert(result, { text = "", cstart = #text })
      break
    end
  end

  if #result == 0 then
    table.insert(result, { text = "", cstart = 0 })
  end
  return result
end

-- Find the byte offset within line_text closest to x_pixel (UTF-8 aware).
-- Returns a 0-indexed byte offset suitable for use as cursor_pos offset within the line.
local function line_x_to_char(font, line_text, x_pixel)
  local prev_w = 0
  local i = 1  -- 1-indexed start of current UTF-8 character
  while i <= #line_text do
    local ok, ni = pcall(utf8.offset, line_text, 2, i)
    if not ok or not ni then ni = #line_text + 1 end
    local w = font:get_width(line_text:sub(1, ni - 1))
    if x_pixel < (prev_w + w) / 2 then
      return i - 1  -- byte offset before current char
    end
    prev_w = w
    i = ni
  end
  return #line_text
end


---------------------------------------------------------------------------
-- Markdown rendering helpers
---------------------------------------------------------------------------

-- Parse inline markdown into tokens: { text, style }
-- Styles: "normal", "bold", "italic", "bold_italic", "code"
local function md_inline_tokens(str)
  local out = {}
  local i = 1
  local len = #str
  while i <= len do
    local ch = str:sub(i, i)
    if ch == '*' then
      if str:sub(i, i+2) == '***' then
        local e = str:find('%*%*%*', i+3, true)
        if e then
          table.insert(out, { str:sub(i+3, e-1), "bold_italic" })
          i = e + 3
        else
          table.insert(out, { ch, "normal" }); i = i + 1
        end
      elseif str:sub(i, i+1) == '**' then
        local e = str:find('%*%*', i+2, true)
        if e then
          table.insert(out, { str:sub(i+2, e-1), "bold" })
          i = e + 2
        else
          table.insert(out, { ch, "normal" }); i = i + 1
        end
      else
        local j = i + 1
        local found = false
        while j <= len do
          if str:sub(j, j) == '*' and str:sub(j, j+1) ~= '**' then
            table.insert(out, { str:sub(i+1, j-1), "italic" })
            i = j + 1; found = true; break
          end
          j = j + 1
        end
        if not found then table.insert(out, { ch, "normal" }); i = i + 1 end
      end
    elseif ch == '`' then
      local e = str:find('`', i+1, true)
      if e then
        table.insert(out, { str:sub(i+1, e-1), "code" })
        i = e + 1
      else
        table.insert(out, { ch, "normal" }); i = i + 1
      end
    else
      local next_s = str:find('[*`]', i)
      if next_s then
        table.insert(out, { str:sub(i, next_s-1), "normal" })
        i = next_s
      else
        table.insert(out, { str:sub(i), "normal" })
        i = len + 1
      end
    end
  end
  return out
end

-- Draw one wrapped line with inline markdown formatting.
local function md_draw_line(font, code_font, text, x, y, colors)
  local tokens = md_inline_tokens(text)
  local cx = x
  for _, tok in ipairs(tokens) do
    local s, sty = tok[1], tok[2]
    if s ~= "" then
      if sty == "bold" then
        cx = renderer.draw_text(style.syntax_fonts["markdown_bold"] or font, s, cx, y, colors.bold)
      elseif sty == "italic" then
        cx = renderer.draw_text(style.syntax_fonts["markdown_italic"] or font, s, cx, y, colors.italic)
      elseif sty == "bold_italic" then
        cx = renderer.draw_text(style.syntax_fonts["markdown_bold_italic"] or font, s, cx, y, colors.bold)
      elseif sty == "code" then
        cx = renderer.draw_text(code_font, s, cx, y, colors.code)
      else
        cx = renderer.draw_text(font, s, cx, y, colors.normal)
      end
    end
  end
  return cx
end

-- Render a full markdown message block. Returns new y after rendering.
-- code_copy_rects: optional table to collect {rect, content} for copy buttons
local function md_render(text, font, code_font, ox, start_y, w, line_h, pad, colors, code_copy_rects)
  if not text or text == "" then return start_y end
  local y = start_y
  local max_text_w = w - pad * 2
  -- Split into raw lines (preserve blank lines)
  local raw_lines = {}
  local s = 1
  while true do
    local nl = text:find("\n", s, true)
    table.insert(raw_lines, text:sub(s, nl and nl - 1 or nil))
    if not nl then break end
    s = nl + 1
  end
  local i = 1
  while i <= #raw_lines do
    local line = raw_lines[i]
    -- Fenced code block
    if line:match("^```") then
      -- Extract language and optional filename from opening fence
      -- Patterns: ```lua, ```lua path/to/file.lua, ```python src/foo.py
      local lang = line:match("^```(%a[%w_%-]*)") or ""
      local block_file = line:match("^```%a[%w_%-]*%s+(%S[^\r\n]*)") or
                         line:match("^```%s+(%S[^\r\n]*)")
      if block_file then block_file = block_file:match("^%s*(.-)%s*$") end  -- trim

      local code_lines = {}
      i = i + 1
      while i <= #raw_lines and not raw_lines[i]:match("^```%s*$") do
        -- Also detect "# filename: path" as first comment inside block
        if not block_file and #code_lines == 0 then
          block_file = raw_lines[i]:match("^[/#%-%-]+%s*[Ff]ile(?:name)?:%s*(%S+)")
            or raw_lines[i]:match("^[/#%-%-]+%s*path:%s*(%S+)")
        end
        table.insert(code_lines, raw_lines[i])
        i = i + 1
      end
      i = i + 1  -- skip closing ```
      local block_h = math.max(1, #code_lines) * line_h + 4
      local bg = style.background2 or style.background
      local block_x = ox + pad / 2
      local block_w = max_text_w + pad
      renderer.draw_rect(block_x, y, block_w, block_h, { bg[1], bg[2], bg[3], 200 })
      -- "Copy" and "Apply" / "Apply→file" buttons in top-right
      if code_copy_rects then
        local content = table.concat(code_lines, "\n")
        local bh = line_h - 2
        local bx = block_x + block_w - 2
        local accent = style.accent or style.caret or style.text
        -- Copy button
        local copy_lbl = "Copy"
        local cw = font:get_width(copy_lbl) + 6
        bx = bx - cw
        renderer.draw_rect(bx, y + 1, cw, bh, { bg[1], bg[2], bg[3], 255 })
        renderer.draw_text(font, copy_lbl, bx + 3, y + 2, style.dim)
        table.insert(code_copy_rects, { rect={x=bx,y=y+1,w=cw,h=bh}, content=content, action="copy" })
        -- Apply button (label shows target file if known)
        local apply_lbl = block_file and ("Apply\xE2\x86\x92" .. common.basename(block_file)) or "Apply"
        local aw = font:get_width(apply_lbl) + 6
        bx = bx - aw - 2
        renderer.draw_rect(bx, y + 1, aw, bh, { accent[1], accent[2], accent[3], 30 })
        renderer.draw_text(font, apply_lbl, bx + 3, y + 2, accent)
        table.insert(code_copy_rects, {
          rect    = { x=bx, y=y+1, w=aw, h=bh },
          content = content,
          action  = block_file and "apply_file" or "apply",
          file    = block_file,  -- relative path from project root (may be nil)
        })
      end
      for _, cl in ipairs(code_lines) do
        renderer.draw_text(code_font, cl, ox + pad, y + 2, colors.code)
        y = y + line_h
      end
      if #code_lines == 0 then y = y + line_h end
      y = y + 4
    -- Blank line
    elseif line:match("^%s*$") then
      y = y + math.floor(line_h * 0.5)
      i = i + 1
    -- Heading
    elseif line:match("^#+%s") then
      local hashes, rest = line:match("^(#+)%s+(.*)")
      local hfont = (#hashes == 1) and (style.syntax_fonts["markdown_bold"] or font) or font
      renderer.draw_text(hfont, rest or "", ox + pad, y, colors.heading)
      y = y + line_h
      i = i + 1
    -- Horizontal rule
    elseif line:match("^%-%-%-+%s*$") or line:match("^%*%*%*+%s*$") or line:match("^___+%s*$") then
      local mid_y = y + math.floor(line_h / 2)
      renderer.draw_rect(ox + pad, mid_y, max_text_w, 1,
        { colors.normal[1], colors.normal[2], colors.normal[3], 50 })
      y = y + line_h
      i = i + 1
    -- Bullet list
    elseif line:match("^%s*[%-%*]%s+") then
      local indent = line:match("^(%s*)")
      local rest = line:match("^%s*[%-%*]%s+(.*)")
      local indent_px = #indent * font:get_width(" ") + pad
      renderer.draw_text(font, "-", ox + indent_px, y, colors.normal)
      local bullet_w = font:get_width("  ")
      local bx = ox + indent_px + bullet_w
      local bmax = max_text_w - indent_px - bullet_w
      local wrapped = word_wrap(font, rest or "", bmax)
      for _, wl in ipairs(wrapped) do
        md_draw_line(font, code_font, wl, bx, y, colors)
        y = y + line_h
      end
      if #wrapped == 0 then y = y + line_h end
      i = i + 1
    -- Numbered list
    elseif line:match("^%s*%d+[%.%)]%s+") then
      local num, rest = line:match("^%s*(%d+[%.%)])%s+(.*)")
      renderer.draw_text(font, num, ox + pad, y, colors.normal)
      local numw = font:get_width(num .. " ")
      local bx = ox + pad + numw
      local wrapped = word_wrap(font, rest or "", max_text_w - numw)
      for _, wl in ipairs(wrapped) do
        md_draw_line(font, code_font, wl, bx, y, colors)
        y = y + line_h
      end
      if #wrapped == 0 then y = y + line_h end
      i = i + 1
    -- Normal paragraph
    else
      local wrapped = word_wrap(font, line, max_text_w)
      for _, wl in ipairs(wrapped) do
        md_draw_line(font, code_font, wl, ox + pad, y, colors)
        y = y + line_h
      end
      if #wrapped == 0 then y = y + line_h end
      i = i + 1
    end
  end
  return y
end


---------------------------------------------------------------------------
-- Tab definitions (shared between dropdown button and menu)
---------------------------------------------------------------------------
local TAB_ORDER  = { "chat", "agents", "knowledge", "context", "decisions" }
local TAB_LABELS = { chat="Chat", agents="Agents", knowledge="Knowledge",
                     context="Context", decisions="Decisions" }
local DROPDOWN_ARROW = "\xe2\x96\xbe"   -- ▾  (U+25BE)

local SLASH_COMMANDS = {
  { cmd = "/review",    desc = "Review git diff (HEAD, staged, or file)" },
  { cmd = "/explain",   desc = "Explain selected code in business terms" },
  { cmd = "/adr",       desc = "Create an Architecture Decision Record" },
  { cmd = "/eks-setup", desc = "Bootstrap knowledge base for this project" },
}

---------------------------------------------------------------------------
-- AIChatView
---------------------------------------------------------------------------
local AIChatView = View:extend()
function AIChatView:__tostring() return "AIChatView" end

function AIChatView:new()
  AIChatView.super.new(self)
  self.scrollable = true
  self.target_size = config.plugins.aichat.size
  self.visible = true
  self.init_size = true
  -- Tabs
  self.current_tab = "chat"   -- "chat", "agents", "knowledge"
  self.tab_rects = {}               -- kept for legacy code paths
  self.dropdown_open           = false
  self.tab_dropdown_rect       = nil
  self.tab_dropdown_item_rects = {}
  -- Input
  self.input_text = ""
  self.cursor_pos = 0
  self.input_focused = false
  self.blink_timer = 0
  -- Hover/click tracking
  self.hovered_zone = nil
  self.header_btns = {}
  self.login_btn_rect = nil
  self.send_btn_rect = nil
  self.input_rect = nil
  self.agent_rects = {}       -- clickable agent list items
  self.agent_del_rects = {}   -- delete buttons per agent
  self.knowledge_rects = {}   -- full row rects for hover
  self.knowledge_cb_rects = {} -- checkbox area only (toggle)
  self.eks_rects = {}         -- full row rects for hover
  self.eks_cb_rects = {}      -- checkbox area only (toggle)
  self.eks_edit_rects = {}    -- [Edit] button rects per row
  self.eks_new_rect = nil     -- [+ New .md] button
  self.eks_mtime_check = 0    -- last mtime poll time
  self.create_folder_rect = nil
  self.create_glyph_rect = nil
  self.refresh_auth_rect = nil
  self.refresh_rect = nil
  self.last_content_height = 0
  self.should_scroll_bottom = false
  self.adr_rects = {}        -- clickable ADR rows in Decisions tab
  -- @mention autocomplete
  self.mention_mode     = false
  self.mention_at_pos   = 0        -- byte offset of the '@' in input_text
  self.mention_filtered = {}       -- filtered file list
  self.mention_sel      = 1        -- selected item (1-based)
  self.mention_item_rects = {}
  -- /command completions
  self.cmd_mode         = false
  self.cmd_filtered     = {}       -- filtered SLASH_COMMANDS
  self.cmd_sel          = 1        -- selected item (1-based)
  self.cmd_item_rects   = {}
  -- diff preview modal
  self.diff_preview     = nil      -- { title, diff, scroll_y, apply_cb, confirm_rect, cancel_rect }
  -- input history (↑/↓ navigation like a terminal)
  self.input_history    = {}       -- list of submitted inputs (most recent last)
  self.history_idx      = nil      -- nil = not navigating; integer = index into history
  self.history_draft    = ""       -- saved draft before entering history navigation
  -- code block copy buttons
  self.code_copy_rects  = {}       -- {rect, content} per code block per frame
end

function AIChatView:get_name() return "AI Chat" end

function AIChatView:set_target_size(axis, value)
  if axis == "x" then self.target_size = value; return true end
end

function AIChatView:update()
  local dest = self.visible and self.target_size or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self:move_towards(self.size, "x", dest, nil, "aichat")
  end
  if self.visible and not auth_checked then check_auth_status() end
  -- Detect project directory change → force rescan
  if self.visible then
    local cur_proj = (core.project_directories and #core.project_directories > 0)
      and core.project_directories[1].name or nil
    if cur_proj ~= knowledge_last_proj then knowledge_scanned = false end
    if cur_proj ~= eks_last_proj then eks_scanned = false end
  end
  if self.visible and not knowledge_scanned then scan_knowledge() end
  if self.visible and not eks_scanned then scan_eks() end
  -- Auto-reload EKS when files are modified on disk (mtime polling every 4s)
  if self.visible and #eks_files > 0 then
    local now = os.time()
    if now - (self.eks_mtime_check or 0) >= 4 then
      self.eks_mtime_check = now
      for _, ef in ipairs(eks_files) do
        local info = pcall(system.get_file_info, ef.path) and system.get_file_info(ef.path)
        if info and info.modified ~= ef.last_mtime then
          ef.last_mtime = info.modified
          core.log("EKS reloaded: " .. ef.name)
          core.redraw = true
        end
      end
    end
  end
  if self.input_focused then
    self.blink_timer = self.blink_timer + 1/config.fps
    if self.blink_timer > config.blink_period then
      self.blink_timer = self.blink_timer - config.blink_period
    end
    core.redraw = true
  end
  -- Smart auto-scroll: only pull to bottom when the user is already near the
  -- bottom (scroll target within ~3 line-heights of the new end).
  -- If they scrolled up to read history, leave their position alone.
  if self.should_scroll_bottom then
    self.should_scroll_bottom = false
    local max_s  = math.max(0, self.last_content_height - self.size.y)
    local line_h = (style.font and style.font:get_height() or 16) + 2
    -- Compare against scroll.to.y (the animated target), not scroll.y (current).
    -- This correctly handles: user was at bottom, content grew → target is still
    -- close to the new max_s, so we keep scrolling.
    -- scroll.to.y == 0 covers the very first message in a fresh conversation.
    local near_bottom = (max_s - self.scroll.to.y) < line_h * 3
    if near_bottom or self.scroll.to.y == 0 then
      self.scroll.to.y = max_s
      core.redraw = true
    end
  end
  AIChatView.super.update(self)
end

function AIChatView:get_scrollable_size()
  return self.last_content_height or self.size.y
end

function AIChatView:export_to_markdown()
  local agent = get_active_agent()
  local parts = {}
  table.insert(parts, "# " .. agent.name .. "\n")
  table.insert(parts, "_Exported " .. os.date("%Y-%m-%d %H:%M") .. "_\n")
  table.insert(parts, "")
  for _, msg in ipairs(agent.messages) do
    if msg.role == "user" then
      table.insert(parts, "---\n\n**You:** " .. msg.text .. "\n")
    elseif msg.role == "assistant" then
      table.insert(parts, "**Claude:**\n\n" .. msg.text .. "\n")
    else
      table.insert(parts, "_System: " .. msg.text .. "_\n")
    end
  end
  local content = table.concat(parts, "\n")
  -- Open as a new unsaved document
  local doc = core.open_doc()
  doc:insert(1, 1, content)
  core.root_view:open_doc(doc)
  core.log("Chat exported to new document.")
end

function AIChatView:eks_new_file()
  -- Create a new .md file in the project's .glyph/ folder and open it
  local cur_proj = core.project_directories and #core.project_directories > 0
    and core.project_directories[1].name or nil
  if not cur_proj then core.log("No project open."); return end
  local glyph_dir = cur_proj .. PATHSEP .. ".glyph"
  local info = system.get_file_info(glyph_dir)
  if not info then
    pcall(system.mkdir, glyph_dir)
  end
  -- Generate a unique filename
  local base = "notes-" .. os.date("%Y%m%d")
  local path = glyph_dir .. PATHSEP .. base .. ".md"
  local n = 1
  while system.get_file_info(path) do
    n = n + 1
    path = glyph_dir .. PATHSEP .. base .. "-" .. n .. ".md"
  end
  local f = io.open(path, "w")
  if f then
    f:write("# Notes\n\n")
    f:close()
    eks_scanned = false
    pcall(function() core.root_view:open_doc(core.open_doc(path)) end)
    core.log("Created: " .. path)
  end
end


---------------------------------------------------------------------------
-- Draw: Header + Tab bar
---------------------------------------------------------------------------
function AIChatView:draw_header(ox, oy, w)
  local font = style.font
  local pad = style.padding.x
  local accent = style.accent or style.caret or style.text
  local header_h = font:get_height() + pad * 2

  -- Background
  renderer.draw_rect(ox, oy, w, header_h, style.background2)
  renderer.draw_rect(ox, oy + header_h - style.divider_size, w, style.divider_size, style.dim)

  -- Title
  local agent = get_active_agent()
  local title = agent.status == "running" and (agent.name .. " ...") or agent.name
  renderer.draw_text(font, title, ox + pad, oy + pad / 2 + 2, accent)

  -- Header buttons: [↓md] [+] [x]
  self.header_btns = {}
  local hbtn_labels = { "\xe2\x86\x93md", "+", "x" }
  local hbtn_cmds = { "export", "new", "close" }
  local hbx = ox + w - pad / 2
  for i = #hbtn_labels, 1, -1 do
    local lbl = hbtn_labels[i]
    local bw = font:get_width(lbl) + pad
    local bh = font:get_height() + 4
    hbx = hbx - bw
    local by = oy + (header_h - bh) / 2
    local hov = (self.hovered_zone == "hdr_" .. hbtn_cmds[i])
    renderer.draw_text(font, lbl, hbx + (bw - font:get_width(lbl)) / 2, by + 2,
      hov and style.text or style.dim)
    self.header_btns[#self.header_btns + 1] = { x = hbx, y = by, w = bw, h = bh, cmd = hbtn_cmds[i] }
    hbx = hbx - 2
  end

  return header_h
end


-- Draws the single [Current Tab ▾] dropdown trigger button.
-- Returns the button height (same as the old tab bar, so fixed_top is unchanged).
function AIChatView:draw_tab_bar(ox, oy, w)
  local font   = style.font
  local pad    = style.padding.x
  local accent = style.accent or style.caret or style.text
  local tab_h  = font:get_height() + pad

  -- Background strip
  renderer.draw_rect(ox, oy, w, tab_h, style.background)
  renderer.draw_rect(ox, oy + tab_h - style.divider_size, w, style.divider_size, style.dim)

  -- Button label: "Chat ▾" (or whichever tab is active)
  local label    = (TAB_LABELS[self.current_tab] or self.current_tab) .. "  " .. DROPDOWN_ARROW
  local btn_w    = font:get_width(label) + pad * 2
  local btn_x    = ox + pad / 2
  local is_hov   = (self.hovered_zone == "tab_dropdown_btn")
  local is_open  = self.dropdown_open

  -- Subtle highlight when hovered or open
  if is_hov or is_open then
    renderer.draw_rect(btn_x, oy + 2, btn_w, tab_h - 4,
      { (accent[1] or 100), (accent[2] or 150), (accent[3] or 255), 25 })
  end

  renderer.draw_text(font, label, btn_x + pad / 2, oy + pad / 2,
    (is_hov or is_open) and style.text or style.dim)

  self.tab_dropdown_rect = { x = btn_x, y = oy, w = btn_w, h = tab_h }
  -- tab_rects kept empty; legacy click-handling loop becomes a no-op
  self.tab_rects = {}
  return tab_h
end

-- Draws the floating dropdown menu (called LAST in draw() so it renders on top).
function AIChatView:draw_tab_dropdown_menu()
  if not self.dropdown_open or not self.tab_dropdown_rect then
    self.tab_dropdown_item_rects = {}  -- clear stale hit areas when dropdown is closed
    return
  end
  local font   = style.font
  local pad    = style.padding.x
  local accent = style.accent or style.caret or style.text
  local line_h = font:get_height() + 6

  -- Measure widest label to set menu width
  local menu_w = 0
  for _, id in ipairs(TAB_ORDER) do
    local lw = font:get_width(TAB_LABELS[id]) + pad * 2
    if lw > menu_w then menu_w = lw end
  end
  menu_w = math.max(menu_w, self.tab_dropdown_rect.w)

  local menu_h = #TAB_ORDER * line_h + 4
  local menu_x = self.tab_dropdown_rect.x
  -- Position right below the trigger button
  local menu_y = self.tab_dropdown_rect.y + self.tab_dropdown_rect.h

  -- Shadow / background
  renderer.draw_rect(menu_x, menu_y, menu_w, menu_h, style.background2)
  renderer.draw_rect(menu_x, menu_y, menu_w, 1, style.dim)
  renderer.draw_rect(menu_x, menu_y + menu_h - 1, menu_w, 1, style.dim)
  renderer.draw_rect(menu_x, menu_y, 1, menu_h, style.dim)
  renderer.draw_rect(menu_x + menu_w - 1, menu_y, 1, menu_h, style.dim)

  self.tab_dropdown_item_rects = {}
  for i, id in ipairs(TAB_ORDER) do
    local iy      = menu_y + 2 + (i - 1) * line_h
    local is_cur  = (self.current_tab == id)
    local is_hov  = (self.hovered_zone == "tab_dropdown_item_" .. id)

    if is_cur then
      renderer.draw_rect(menu_x + 1, iy, menu_w - 2, line_h,
        { (accent[1] or 100), (accent[2] or 150), (accent[3] or 255), 30 })
    elseif is_hov then
      renderer.draw_rect(menu_x + 1, iy, menu_w - 2, line_h,
        { (style.text[1] or 200), (style.text[2] or 200), (style.text[3] or 200), 15 })
    end

    local col = is_cur and accent or (is_hov and style.text or style.dim)
    renderer.draw_text(font, TAB_LABELS[id], menu_x + pad, iy + 3, col)

    self.tab_dropdown_item_rects[#self.tab_dropdown_item_rects + 1] = {
      x = menu_x, y = iy, w = menu_w, h = line_h, id = id
    }
  end
end


---------------------------------------------------------------------------
-- Diff preview: line-level unified diff + modal overlay
---------------------------------------------------------------------------
local function split_lines(text)
  local t = {}
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do table.insert(t, l) end
  if t[#t] == "" then table.remove(t) end
  return t
end

local function compute_diff(old_text, new_text)
  local old = split_lines(old_text)
  local new = split_lines(new_text)
  local n, m = #old, #new
  -- Guard: very large files → skip diff, just report size
  if n * m > 60000 then return nil, n, m end
  -- LCS DP
  local dp = {}
  for i = 0, n do
    dp[i] = {}
    for j = 0, m do dp[i][j] = 0 end
  end
  for i = 1, n do
    for j = 1, m do
      if old[i] == new[j] then dp[i][j] = dp[i-1][j-1] + 1
      else dp[i][j] = math.max(dp[i-1][j], dp[i][j-1]) end
    end
  end
  -- Backtrack
  local result = {}
  local i, j = n, m
  while i > 0 or j > 0 do
    if i > 0 and j > 0 and old[i] == new[j] then
      table.insert(result, 1, { kind = "=", text = old[i] })
      i = i - 1; j = j - 1
    elseif j > 0 and (i == 0 or dp[i][j-1] >= dp[i-1][j]) then
      table.insert(result, 1, { kind = "+", text = new[j] })
      j = j - 1
    else
      table.insert(result, 1, { kind = "-", text = old[i] })
      i = i - 1
    end
  end
  return result, n, m
end

-- Collapse long runs of unchanged lines, keeping CONTEXT lines around changes.
local DIFF_CONTEXT = 3
local function collapse_context(diff)
  if not diff then return diff end
  local out = {}
  local n = #diff
  -- Mark which lines are "near a change"
  local near = {}
  for i = 1, n do
    if diff[i].kind ~= "=" then
      for k = math.max(1, i - DIFF_CONTEXT), math.min(n, i + DIFF_CONTEXT) do
        near[k] = true
      end
    end
  end
  local skipped = 0
  for i = 1, n do
    if near[i] then
      if skipped > 0 then
        table.insert(out, { kind = "...", text = string.format("  ... %d unchanged lines ...", skipped) })
        skipped = 0
      end
      table.insert(out, diff[i])
    else
      skipped = skipped + 1
    end
  end
  if skipped > 0 then
    table.insert(out, { kind = "...", text = string.format("  ... %d unchanged lines ...", skipped) })
  end
  return out
end

function AIChatView:open_diff_preview(cb)
  local new_content = cb.content
  if new_content:sub(-1) ~= "\n" then new_content = new_content .. "\n" end
  local old_content = ""
  local title
  if cb.action == "apply_file" and cb.file then
    local cur_proj = core.project_directories and #core.project_directories > 0
      and core.project_directories[1].name or nil
    local full_path = cur_proj
      and (cur_proj .. PATHSEP .. cb.file:gsub("/", PATHSEP))
      or cb.file
    local f = io.open(full_path, "r")
    if f then old_content = f:read("*a") or ""; f:close() end
    title = "Preview: " .. cb.file
  else
    local av = core.active_view
    local doc = av and av.doc
    if doc then
      old_content = table.concat(doc.lines)
    end
    local name = doc and doc.filename and common.basename(doc.filename) or "active document"
    title = "Preview: " .. name
  end
  local diff, old_n, new_n = compute_diff(old_content, new_content)
  self.diff_preview = {
    title        = title,
    diff         = diff and collapse_context(diff) or nil,
    old_n        = old_n,
    new_n        = new_n,
    scroll_y     = 0,
    apply_cb     = cb,
    confirm_rect = nil,
    cancel_rect  = nil,
  }
  core.redraw = true
end

function AIChatView:draw_diff_preview()
  local dp = self.diff_preview
  if not dp then return end
  local px, py = self.position.x, self.position.y
  local sw, sh = self.size.x, self.size.y
  -- Dim the entire view
  renderer.draw_rect(px, py, sw, sh, { 0, 0, 0, 140 })
  -- Panel geometry
  local pad = style.padding.x
  local panel_x = px + pad * 2
  local panel_y = py + pad * 2
  local panel_w = sw - pad * 4
  local panel_h = sh - pad * 4
  renderer.draw_rect(panel_x, panel_y, panel_w, panel_h, style.background)
  renderer.draw_rect(panel_x, panel_y, panel_w, 1, style.dim)
  renderer.draw_rect(panel_x, panel_y + panel_h, panel_w, 1, style.dim)
  -- Header
  local font = style.font
  local lh   = font:get_height() + 2
  local hdr_h = lh + pad
  renderer.draw_rect(panel_x, panel_y, panel_w, hdr_h, style.background2 or style.background)
  renderer.draw_rect(panel_x, panel_y + hdr_h - 1, panel_w, 1, style.dim)
  renderer.draw_text(font, dp.title, panel_x + pad, panel_y + pad / 2, style.text)
  -- Footer (buttons)
  local btn_h  = lh + pad
  local foot_y = panel_y + panel_h - btn_h
  renderer.draw_rect(panel_x, foot_y, panel_w, btn_h, style.background2 or style.background)
  renderer.draw_rect(panel_x, foot_y, panel_w, 1, style.dim)
  local accent = style.accent or style.caret or style.text
  -- Cancel
  local cancel_lbl = "Cancel"
  local cw = font:get_width(cancel_lbl) + pad * 2
  local cx = panel_x + pad
  renderer.draw_rect(cx, foot_y + 4, cw, btn_h - 8,
    { style.dim[1], style.dim[2], style.dim[3], 40 })
  renderer.draw_text(font, cancel_lbl, cx + pad, foot_y + (btn_h - lh) / 2, style.dim)
  dp.cancel_rect = { x = cx, y = foot_y + 4, w = cw, h = btn_h - 8 }
  -- Confirm
  local confirm_lbl = "Apply Changes"
  local aw = font:get_width(confirm_lbl) + pad * 2
  local ax = panel_x + panel_w - aw - pad
  renderer.draw_rect(ax, foot_y + 4, aw, btn_h - 8,
    { accent[1], accent[2], accent[3], 60 })
  renderer.draw_text(font, confirm_lbl, ax + pad, foot_y + (btn_h - lh) / 2, accent)
  dp.confirm_rect = { x = ax, y = foot_y + 4, w = aw, h = btn_h - 8 }
  -- Diff content area
  local content_y = panel_y + hdr_h
  local content_h = foot_y - content_y
  local code_font = style.code_font or font
  local clh = code_font:get_height() + 1
  -- Colors
  local add_bg  = { 80, 200, 80, 25 }
  local del_bg  = { 200, 80, 80, 25 }
  local add_col = { 100, 220, 100, 255 }
  local del_col = { 220, 100, 100, 255 }
  local ctx_col = { style.dim[1], style.dim[2], style.dim[3], 180 }
  local ell_col = { style.dim[1], style.dim[2], style.dim[3], 120 }
  if not dp.diff then
    -- Too large: just show stats
    local msg = string.format("File too large to diff (%d → %d lines). Click Apply to proceed.",
      dp.old_n or 0, dp.new_n or 0)
    renderer.draw_text(font, msg, panel_x + pad, content_y + pad, style.text)
  else
    local total_h = #dp.diff * clh
    local max_scroll = math.max(0, total_h - content_h)
    dp.scroll_y = math.max(0, math.min(dp.scroll_y or 0, max_scroll))
    -- Draw visible diff lines
    for i, line in ipairs(dp.diff) do
      local ly = content_y + (i - 1) * clh - dp.scroll_y
      if ly + clh < content_y then goto continue end
      if ly > content_y + content_h then break end
      if line.kind == "+" then
        renderer.draw_rect(panel_x, ly, panel_w, clh, add_bg)
        renderer.draw_text(code_font, "+ " .. line.text, panel_x + pad, ly, add_col)
      elseif line.kind == "-" then
        renderer.draw_rect(panel_x, ly, panel_w, clh, del_bg)
        renderer.draw_text(code_font, "- " .. line.text, panel_x + pad, ly, del_col)
      elseif line.kind == "..." then
        renderer.draw_text(font, line.text, panel_x + pad, ly, ell_col)
      else
        renderer.draw_text(code_font, "  " .. line.text, panel_x + pad, ly, ctx_col)
      end
      ::continue::
    end
    -- Scrollbar
    if total_h > content_h then
      local sb_w = 4
      local ratio = content_h / total_h
      local sb_h  = math.max(20, content_h * ratio)
      local sb_y  = content_y + (dp.scroll_y / max_scroll) * (content_h - sb_h)
      renderer.draw_rect(panel_x + panel_w - sb_w - 2, sb_y, sb_w, sb_h, style.dim)
    end
  end
end

function AIChatView:do_apply(cb)
  local content = cb.content
  if content:sub(-1) ~= "\n" then content = content .. "\n" end
  if cb.action == "apply_file" and cb.file then
    local cur_proj = core.project_directories and #core.project_directories > 0
      and core.project_directories[1].name or nil
    local full_path = cur_proj
      and (cur_proj .. PATHSEP .. cb.file:gsub("/", PATHSEP))
      or cb.file
    local parent = common.dirname(full_path)
    if parent and parent ~= "" then pcall(system.mkdir, parent) end
    local f = io.open(full_path, "w")
    if f then
      f:write(content); f:close()
      core.try(function()
        core.root_view:open_doc(core.open_doc(full_path))
      end)
      core.log("Applied: " .. cb.file)
    else
      core.log("Error: could not write to " .. full_path)
    end
  else
    local av = core.active_view
    local doc = av and av.doc
    if doc then
      doc:remove(1, 1, #doc.lines, #doc.lines[#doc.lines])
      doc:insert(1, 1, content)
      core.log("Applied code block to " .. (doc.filename and common.basename(doc.filename) or "untitled"))
    else
      local nd = core.open_doc()
      nd:insert(1, 1, cb.content)
      core.root_view:open_doc(nd)
      core.log("Opened code block in new document.")
    end
  end
end

---------------------------------------------------------------------------
-- Draw: Chat tab
---------------------------------------------------------------------------
function AIChatView:draw_chat_tab(ox, oy, w, max_y)
  local font = style.font
  local pad = style.padding.x
  local line_h = font:get_height() + 2
  local accent = style.accent or style.caret or style.text
  local agent = get_active_agent()
  local y = oy + pad / 2

  self.login_btn_rect = nil
  self.refresh_auth_rect = nil

  if #agent.messages == 0 then
    -- Empty state: auth info + hints
    local cy = y + pad

    if auth_info then
      if auth_info.loggedIn then
        renderer.draw_rect(ox + pad, cy + math.floor(font:get_height() / 2) - 3, 6, 6,
          { 100, 220, 100, 255 })
        renderer.draw_text(font, auth_info.email or "Logged in", ox + pad + 12, cy, style.text)
        cy = cy + line_h
        local sub = (auth_info.subscriptionType or ""):upper() .. " via " .. (auth_info.authMethod or "?")
        renderer.draw_text(font, sub, ox + pad + 12, cy, style.dim)
        cy = cy + line_h
        renderer.draw_text(font, "Model: " .. config.plugins.aichat.model, ox + pad + 12, cy, style.dim)
        cy = cy + line_h * 2
      else
        renderer.draw_rect(ox + pad, cy + math.floor(font:get_height() / 2) - 3, 6, 6,
          { 220, 80, 80, 255 })
        renderer.draw_text(font, auth_info.error or "Not logged in", ox + pad + 12, cy, style.dim)
        cy = cy + line_h
        -- Login button
        local btn_label = "Login with Claude.ai"
        local btn_w = font:get_width(btn_label) + pad * 2
        local btn_h = line_h + 4
        local btn_x = ox + pad
        local btn_y = cy + 4
        local btn_hov = (self.hovered_zone == "login")
        renderer.draw_rect(btn_x, btn_y, btn_w, btn_h, btn_hov and accent or style.background2)
        renderer.draw_rect(btn_x, btn_y, btn_w, 1, style.dim)
        renderer.draw_rect(btn_x, btn_y + btn_h - 1, btn_w, 1, style.dim)
        renderer.draw_rect(btn_x, btn_y, 1, btn_h, style.dim)
        renderer.draw_rect(btn_x + btn_w - 1, btn_y, 1, btn_h, style.dim)
        renderer.draw_text(font, btn_label,
          btn_x + (btn_w - font:get_width(btn_label)) / 2,
          btn_y + (btn_h - font:get_height()) / 2,
          btn_hov and style.background or style.text)
        self.login_btn_rect = { x = btn_x, y = btn_y, w = btn_w, h = btn_h }
        cy = btn_y + btn_h + pad / 2

        -- Refresh auth button
        local ref_label = "Refresh"
        local ref_w = font:get_width(ref_label) + pad
        local ref_hov = (self.hovered_zone == "refresh_auth")
        renderer.draw_text(font, ref_label, ox + pad, cy,
          ref_hov and accent or style.dim)
        self.refresh_auth_rect = { x = ox + pad, y = cy, w = ref_w, h = line_h }
        cy = cy + line_h + pad
      end
    else
      renderer.draw_text(font, "Checking auth...", ox + pad, cy, style.dim)
      cy = cy + line_h
    end

    -- Knowledge status
    local n_enabled = 0
    for _, kf in ipairs(knowledge_files) do if kf.enabled then n_enabled = n_enabled + 1 end end
    if n_enabled > 0 then
      renderer.draw_text(font, n_enabled .. " knowledge file(s) active", ox + pad, cy, style.dim)
      cy = cy + line_h
    end

    cy = cy + line_h
    local hints = {
      "Ask anything about your code.",
      "",
      "Ctrl+.          focus input",
      "Ctrl+Shift+.    toggle panel",
      "Ctrl+Shift+N    new conversation",
    }
    for _, h in ipairs(hints) do
      if h ~= "" then
        renderer.draw_text(font, h, ox + (w - font:get_width(h)) / 2, cy, style.dim)
      end
      cy = cy + line_h
    end
    return cy
  end

  -- Messages
  local max_text_w = w - pad * 3
  local code_font = style.code_font or font
  self.code_copy_rects = {}  -- reset each frame
  local md_colors = {
    normal  = style.text,
    bold    = style.text,
    italic  = accent,
    code    = (style.syntax and style.syntax.string) or { 190, 145, 80, 255 },
    heading = accent,
  }
  for _, msg in ipairs(agent.messages) do
    local is_user = (msg.role == "user")
    local role_label = is_user and "You" or "Claude"
    local role_color = is_user and (style.syntax and style.syntax.keyword or accent) or accent
    renderer.draw_text(font, role_label, ox + pad, y, role_color)
    y = y + line_h

    if is_user then
      -- User messages: plain word wrap (no markdown)
      local wrapped = word_wrap(font, msg.text, max_text_w)
      for _, wline in ipairs(wrapped) do
        renderer.draw_text(font, wline, ox + pad + 4, y, style.text)
        y = y + line_h
      end
    else
      -- Claude messages: full markdown rendering (with copy buttons)
      y = md_render(msg.text, font, code_font, ox + 4, y, w - 8, line_h, pad, md_colors, self.code_copy_rects)
    end

    y = y + pad / 2
    renderer.draw_rect(ox + pad, y, w - pad * 2, 1, { style.dim[1], style.dim[2], style.dim[3], 40 })
    y = y + pad / 2
  end

  return y
end


---------------------------------------------------------------------------
-- Draw: Agents tab
---------------------------------------------------------------------------
function AIChatView:draw_agents_tab(ox, oy, w, max_y)
  local font = style.font
  local pad = style.padding.x
  local line_h = font:get_height() + 2
  local accent = style.accent or style.caret or style.text
  local y = oy + pad

  self.agent_rects = {}
  self.agent_del_rects = {}

  -- Agent list
  for idx, agent in ipairs(agents) do
    local is_active = (idx == active_agent_idx)
    local is_hovered = (self.hovered_zone == "agent_" .. idx)
    local item_h = line_h * 2 + pad / 2
    local item_y = y

    -- Background for active/hovered
    if is_active then
      renderer.draw_rect(ox + 4, item_y, w - 8, item_h, { accent[1], accent[2], accent[3], 20 })
    elseif is_hovered then
      renderer.draw_rect(ox + 4, item_y, w - 8, item_h,
        { style.text[1], style.text[2], style.text[3], 10 })
    end

    -- Status dot
    local dot_y = item_y + math.floor(line_h / 2) - 3
    local dot_color
    if agent.status == "running" then
      dot_color = { 80, 160, 255, 255 }  -- blue
    elseif is_active then
      dot_color = { 100, 220, 100, 255 }  -- green
    else
      dot_color = { style.dim[1], style.dim[2], style.dim[3], 120 }  -- gray
    end
    renderer.draw_rect(ox + pad, dot_y, 6, 6, dot_color)

    -- Name
    local name_color = is_active and style.text or style.dim
    renderer.draw_text(font, agent.name, ox + pad + 14, item_y, name_color)

    -- Message count (right side)
    local count_str = #agent.messages .. " msgs"
    local count_w = font:get_width(count_str)
    renderer.draw_text(font, count_str, ox + w - pad - count_w - pad, item_y, style.dim)

    -- Delete button [x] (not for default if it's the only one)
    if #agents > 1 then
      local del_label = "x"
      local del_w = font:get_width(del_label) + 8
      local del_x = ox + w - pad - del_w
      local del_y = item_y + line_h
      local del_hov = (self.hovered_zone == "agent_del_" .. idx)
      renderer.draw_text(font, del_label, del_x + 4, del_y,
        del_hov and { 220, 80, 80, 255 } or style.dim)
      self.agent_del_rects[idx] = { x = del_x, y = del_y, w = del_w, h = line_h }
    end

    -- Subtitle: status or time
    local subtitle
    if agent.status == "running" then
      subtitle = "Running..."
    elseif #agent.messages > 0 then
      local elapsed = os.time() - agent.messages[#agent.messages].timestamp
      if elapsed < 60 then subtitle = "Just now"
      elseif elapsed < 3600 then subtitle = math.floor(elapsed / 60) .. " min ago"
      else subtitle = math.floor(elapsed / 3600) .. " h ago" end
    else
      subtitle = "No messages"
    end
    renderer.draw_text(font, subtitle, ox + pad + 14, item_y + line_h, style.dim)

    self.agent_rects[idx] = { x = ox + 4, y = item_y, w = w - 8, h = item_h }
    y = y + item_h + 4
  end

  -- Separator
  y = y + pad / 2
  renderer.draw_rect(ox + pad, y, w - pad * 2, 1, { style.dim[1], style.dim[2], style.dim[3], 40 })
  y = y + pad

  -- Hint
  renderer.draw_text(font, "Type a name below and press",
    ox + pad, y, style.dim)
  y = y + line_h
  renderer.draw_text(font, "Enter to create a new agent.",
    ox + pad, y, style.dim)
  y = y + line_h * 2

  return y
end


---------------------------------------------------------------------------
-- Draw: Knowledge tab (EKS + project knowledge)
---------------------------------------------------------------------------
local function draw_section_header(font, ox, y, w, label, accent, pad)
  local line_h = font:get_height() + 2
  renderer.draw_text(font, label, ox + pad, y, accent)
  y = y + line_h
  renderer.draw_rect(ox + pad, y, w - pad * 2, 1, { accent[1], accent[2], accent[3], 40 })
  y = y + pad / 2
  return y
end

local function draw_button(font, ox, y, label, is_hov, accent, pad)
  local btn_w = font:get_width(label) + pad * 2
  local btn_h = font:get_height() + 4
  renderer.draw_rect(ox, y, btn_w, btn_h, is_hov and accent or style.background2)
  renderer.draw_rect(ox, y, btn_w, 1, style.dim)
  renderer.draw_rect(ox, y + btn_h - 1, btn_w, 1, style.dim)
  renderer.draw_rect(ox, y, 1, btn_h, style.dim)
  renderer.draw_rect(ox + btn_w - 1, y, 1, btn_h, style.dim)
  renderer.draw_text(font, label,
    ox + (btn_w - font:get_width(label)) / 2,
    y + (btn_h - font:get_height()) / 2,
    is_hov and style.background or style.text)
  return btn_w, btn_h
end

function AIChatView:draw_knowledge_tab(ox, oy, w, max_y)
  local font = style.font
  local pad = style.padding.x
  local line_h = font:get_height() + 2
  local accent = style.accent or style.caret or style.text
  local y = oy + pad / 2

  self.knowledge_rects = {}
  self.knowledge_cb_rects = {}
  self.eks_rects = {}
  self.eks_cb_rects = {}
  self.eks_edit_rects = {}
  self.eks_new_rect = nil
  self.create_folder_rect = nil
  self.create_glyph_rect = nil
  self.refresh_rect = nil

  --------------------------------------------------------------------------
  -- EKS section
  --------------------------------------------------------------------------
  y = draw_section_header(font, ox, y, w, "Enterprise Context (.glyph/)", accent, pad)

  local has_project = core.project_directories and #core.project_directories > 0
  if #eks_files == 0 then
    renderer.draw_text(font, "No .glyph/ found.", ox + pad, y, style.dim)
    y = y + line_h
    if has_project then
      local hov = (self.hovered_zone == "create_glyph")
      local bw, bh = draw_button(font, ox + pad, y, "Create .glyph/ structure", hov, accent, pad)
      self.create_glyph_rect = { x = ox + pad, y = y, w = bw, h = bh }
      y = y + bh + pad / 2
    end
  else
    for idx, ef in ipairs(eks_files) do
      local is_hov = (self.hovered_zone == "eks_" .. idx)
      local is_open_hov = (self.hovered_zone == "eks_open_" .. idx)
      local item_h = line_h + 2
      if is_hov or is_open_hov then
        renderer.draw_rect(ox + 4, y, w - 8, item_h, { accent[1], accent[2], accent[3], 12 })
      end
      -- Checkbox ([x]/[ ]) — clicking this toggles enabled
      local cb = ef.enabled and "[x]" or "[ ]"
      local cb_w = font:get_width("[x] ")
      renderer.draw_text(font, cb, ox + pad, y + 1, ef.enabled and accent or style.dim)
      -- Label badge
      local badge = "[" .. ef.label .. "]"
      local badge_x = ox + pad + cb_w
      renderer.draw_text(font, badge, badge_x, y + 1, ef.enabled and accent or style.dim)
      -- Filename — clicking this opens the file
      local name_x = badge_x + font:get_width(badge) + 4
      local name_col = is_open_hov and accent or (ef.enabled and style.text or style.dim)
      renderer.draw_text(font, ef.name, name_x, y + 1, name_col)
      -- Edit button [Edit] (right side, before source badge)
      local edit_lbl = "Edit"
      local edit_w = font:get_width(edit_lbl) + pad
      local edit_x = ox + w - pad - edit_w
      local is_edit_hov = (self.hovered_zone == "eks_edit_" .. idx)
      renderer.draw_text(font, edit_lbl, edit_x, y + 1,
        is_edit_hov and accent or style.dim)
      self.eks_edit_rects[idx] = { x = edit_x, y = y, w = edit_w, h = item_h }
      -- Source badge (to the left of Edit button)
      local src = ef.source == "global" and "g" or "p"
      local src_w = font:get_width(src)
      renderer.draw_text(font, src, edit_x - src_w - 4, y + 1, style.dim)
      -- Store rects: full row + checkbox-only portion
      self.eks_rects[idx]    = { x = ox + 4,          y = y, w = w - 8,            h = item_h }
      self.eks_cb_rects[idx] = { x = ox + pad,         y = y, w = cb_w,             h = item_h }
      y = y + item_h
    end
    -- [+ New .md] button to create a new knowledge file in .glyph/
    if has_project then
      y = y + pad / 4
      local new_hov = (self.hovered_zone == "eks_new")
      local new_lbl = "+ New .md"
      local new_bw = font:get_width(new_lbl) + pad * 2
      local new_bh = font:get_height() + pad
      renderer.draw_rect(ox + pad, y, new_bw, new_bh,
        { accent[1], accent[2], accent[3], new_hov and 40 or 15 })
      renderer.draw_text(font, new_lbl, ox + pad + pad / 2, y + pad / 2,
        new_hov and accent or style.dim)
      self.eks_new_rect = { x = ox + pad, y = y, w = new_bw, h = new_bh }
      y = y + new_bh + pad / 4
      -- "Add .glyph/" button if project has no .glyph yet
      local proj_glyph = core.project_directories[1].name .. PATHSEP .. ".glyph"
      local proj_info = system.get_file_info(proj_glyph)
      if not proj_info then
        local hov = (self.hovered_zone == "create_glyph")
        local bw, bh = draw_button(font, ox + pad, y, "Add .glyph/ to project", hov, accent, pad)
        self.create_glyph_rect = { x = ox + pad, y = y, w = bw, h = bh }
        y = y + bh + pad / 2
      end
    end
  end

  y = y + pad

  --------------------------------------------------------------------------
  -- Project Knowledge section
  --------------------------------------------------------------------------
  y = draw_section_header(font, ox, y, w, "Project Knowledge (knowledge/)", style.text, pad)

  if #knowledge_files == 0 then
    if knowledge_dir_exists then
      renderer.draw_text(font, "knowledge/ folder is empty.", ox + pad, y, style.dim)
      y = y + line_h
      renderer.draw_text(font, "Add .md or .txt files to use as context.", ox + pad, y, style.dim)
      y = y + line_h
    else
      renderer.draw_text(font, "No knowledge/ folder found.", ox + pad, y, style.dim)
      y = y + line_h
      if has_project then
        local hov = (self.hovered_zone == "create_folder")
        local bw, bh = draw_button(font, ox + pad, y, "Create knowledge/ folder", hov, accent, pad)
        self.create_folder_rect = { x = ox + pad, y = y, w = bw, h = bh }
        y = y + bh + pad / 2
      end
    end
  else
    local total_enabled, total_size = 0, 0
    for idx, kf in ipairs(knowledge_files) do
      local is_hov = (self.hovered_zone == "knowledge_" .. idx)
      local is_open_hov = (self.hovered_zone == "knowledge_open_" .. idx)
      local item_h = line_h + 2
      if is_hov or is_open_hov then
        renderer.draw_rect(ox + 4, y, w - 8, item_h, { style.text[1], style.text[2], style.text[3], 10 })
      end
      -- Checkbox — clicking toggles enabled
      local cb = kf.enabled and "[x]" or "[ ]"
      local cb_w = font:get_width("[x] ")
      renderer.draw_text(font, cb, ox + pad, y + 1, kf.enabled and accent or style.dim)
      -- Filename — clicking opens the file
      local name_x = ox + pad + cb_w
      local display = kf.source == "global" and ("* " .. kf.name) or kf.name
      local name_col = is_open_hov and accent or (kf.enabled and style.text or style.dim)
      renderer.draw_text(font, display, name_x, y + 1, name_col)
      -- Size (right)
      local sz = format_size(kf.size)
      renderer.draw_text(font, sz, ox + w - pad - font:get_width(sz), y + 1, style.dim)
      if kf.enabled then total_enabled = total_enabled + 1; total_size = total_size + kf.size end
      self.knowledge_rects[idx]    = { x = ox + 4,  y = y, w = w - 8, h = item_h }
      self.knowledge_cb_rects[idx] = { x = ox + pad, y = y, w = cb_w,  h = item_h }
      y = y + item_h
    end
    y = y + pad / 2
    local summary = total_enabled .. " file(s) · " .. format_size(total_size)
    renderer.draw_text(font, summary, ox + pad, y, style.dim)
    y = y + line_h
  end

  --------------------------------------------------------------------------
  -- Refresh
  --------------------------------------------------------------------------
  y = y + pad
  local ref_hov = (self.hovered_zone == "refresh_knowledge")
  renderer.draw_text(font, "[Refresh all]", ox + pad, y, ref_hov and accent or style.dim)
  self.refresh_rect = { x = ox + pad, y = y, w = font:get_width("[Refresh all]"), h = line_h }
  y = y + line_h + pad

  return y
end


---------------------------------------------------------------------------
-- Draw: Context preview tab
-- Shows exactly what context will be prepended to the next Claude prompt.
---------------------------------------------------------------------------
function AIChatView:draw_context_tab(ox, oy, w, max_y)
  local font  = style.font
  local cfont = style.code_font
  local pad   = style.padding.x
  local line_h = font:get_height() + 2
  local accent = style.accent or style.caret or style.text
  local y = oy + pad

  local agent  = get_active_agent()
  local prefix = build_context_prefix(agent)
  local tokens = math.floor(#prefix / 4)

  -- summary bar
  local summary = string.format("Context to send: ~%d tokens  (%d bytes)", tokens, #prefix)
  renderer.draw_text(font, summary, ox + pad, y, accent)
  y = y + line_h + pad / 2

  -- EKS layer list
  renderer.draw_text(font, "EKS layers:", ox + pad, y, style.dim)
  y = y + line_h
  if #eks_files == 0 then
    renderer.draw_text(font, "  (none — open project with .glyph/ folder)", ox + pad, y, style.dim)
    y = y + line_h
  else
    for _, ef in ipairs(eks_files) do
      local bullet = ef.enabled and "\xE2\x97\x8F " or "\xE2\x97\x8B "
      local color  = ef.enabled and style.text or style.dim
      local lbl = ef.label .. "  " .. ef.name
        .. "  (" .. (ef.source or "?") .. ", " .. math.floor((ef.size or 0) / 1024 + 0.5) .. " KB)"
      renderer.draw_text(font, bullet .. lbl, ox + pad * 2, y, color)
      y = y + line_h
    end
  end
  y = y + pad / 2

  -- active file + selection
  local fi = get_active_file_context()
  local si = get_selection_context()
  if fi then
    renderer.draw_text(font, "Active file:", ox + pad, y, style.dim)
    y = y + line_h
    renderer.draw_text(cfont, "  " .. fi.filename .. " (" .. fi.line_count .. " lines)", ox + pad, y, style.text)
    y = y + line_h
  end
  if si then
    renderer.draw_text(font, "Selection:", ox + pad, y, style.dim)
    y = y + line_h
    renderer.draw_text(cfont, "  lines " .. si.line1 .. "\xE2\x80\x93" .. si.line2, ox + pad, y, style.text)
    y = y + line_h
  end
  y = y + pad

  -- divider
  renderer.draw_rect(ox + pad, y, w - pad * 2, 1, style.dim)
  y = y + pad

  -- full context text (scrollable via view scroll)
  renderer.draw_text(font, "Full context injected before your message:", ox + pad, y, style.dim)
  y = y + line_h

  if #prefix == 0 then
    renderer.draw_text(font, "  (empty)", ox + pad, y, style.dim)
    y = y + line_h
  else
    local s = 1
    while s <= #prefix do
      if y > max_y then break end
      local nl = prefix:find("\n", s, true)
      local l  = prefix:sub(s, nl and nl - 1 or nil)
      renderer.draw_text(cfont, l, ox + pad, y, style.text)
      y = y + line_h
      s = (nl or #prefix) + 1
    end
  end

  return y + pad
end


---------------------------------------------------------------------------
-- Draw: Decisions tab (ADR timeline)
---------------------------------------------------------------------------
function AIChatView:draw_adr_tab(ox, oy, w, max_y)
  local font   = style.font
  local cfont  = style.code_font or font
  local pad    = style.padding.x
  local line_h = font:get_height() + 2
  local accent = style.accent or style.caret or style.text
  local y = oy + pad

  -- Collect ADR files from enabled EKS layers
  local adrs = {}
  for _, ef in ipairs(eks_files) do
    if ef.layer == "adr" then
      table.insert(adrs, ef)
    end
  end

  -- Header row
  local n = #adrs
  local header = n == 0 and "No ADRs yet" or (n .. " decision" .. (n == 1 and "" or "s"))
  renderer.draw_text(font, header, ox + pad, y, accent)
  -- hint
  local hint = "  /adr <title> to create one"
  renderer.draw_text(font, hint, ox + pad + font:get_width(header), y, style.dim)
  y = y + line_h + pad / 2
  renderer.draw_rect(ox + pad, y, w - pad * 2, 1, style.dim)
  y = y + pad / 2

  self.adr_rects = {}

  if n == 0 then
    y = y + line_h
    local msg = "Create your first decision record with /adr"
    renderer.draw_text(font, msg, ox + (w - font:get_width(msg)) / 2, y, style.dim)
    y = y + line_h * 2
    local example = "Example: /adr Use PostgreSQL over MongoDB"
    renderer.draw_text(font, example, ox + (w - font:get_width(example)) / 2, y, style.dim)
    y = y + line_h
    return y + pad
  end

  -- Sort ADRs newest-first (filename starts with YYYY-MM-DD)
  table.sort(adrs, function(a, b) return a.name > b.name end)

  for _, ef in ipairs(adrs) do
    if y > max_y then break end

    -- Parse date and title from filename: "YYYY-MM-DD-slug.md"
    local date, slug = ef.name:match("^(%d%d%d%d%-%d%d%-%d%d)%-?(.*)%.md$")
    local title = slug and slug:gsub("%-", " ") or ef.name:gsub("%.md$", "")
    -- Capitalize first letter
    title = title:sub(1,1):upper() .. title:sub(2)

    local row_y = y
    local row_h = line_h * 2 + 4

    -- Hover highlight
    local hov = (self.hovered_zone == "adr_" .. ef.path)
    if hov then
      renderer.draw_rect(ox + pad / 2, row_y, w - pad, row_h,
        { (accent[1] or 100), (accent[2] or 150), (accent[3] or 255), 20 })
    end

    -- Date badge
    if date then
      renderer.draw_text(cfont, date, ox + pad, y + 2, style.dim)
    end
    local date_w = font:get_width(date or "") + pad / 2

    -- Title
    renderer.draw_text(font, title, ox + pad + date_w, y + 2,
      hov and style.text or (accent))
    y = y + line_h

    -- Source tag (global / project)
    local src_label = "[" .. (ef.source or "?") .. "]"
    renderer.draw_text(cfont, "  " .. src_label, ox + pad, y, style.dim)
    y = y + line_h + 2

    -- Divider
    renderer.draw_rect(ox + pad, y, w - pad * 2, 1,
      { style.dim[1], style.dim[2], style.dim[3], 40 })
    y = y + 2

    -- Store click rect
    table.insert(self.adr_rects, { x = ox, y = row_y, w = w, h = row_h, path = ef.path })
  end

  return y + pad
end

---------------------------------------------------------------------------
-- Draw: Input field (multi-line with word wrap)
---------------------------------------------------------------------------
local INPUT_MAX_LINES = 8

function AIChatView:get_input_text_width()
  local pad = style.padding.x
  local btn_space = style.font:get_width("Send") + pad * 2
  return self.size.x - pad * 2 - btn_space
end

-- Returns cached position-aware wrapped lines for the current input.
function AIChatView:get_wrapped_input()
  local max_w = self:get_input_text_width()
  if self._wrap_text == self.input_text and self._wrap_w == max_w then
    return self._wrap_cache
  end
  self._wrap_cache = input_wrap_pos(style.font, self.input_text, max_w)
  self._wrap_text = self.input_text
  self._wrap_w = max_w
  return self._wrap_cache
end

-- Returns the 1-indexed visual line containing cursor_pos.
function AIChatView:get_cursor_line_idx(wrapped)
  for i = 1, #wrapped - 1 do
    local next_cstart = wrapped[i + 1].cstart
    if self.cursor_pos < next_cstart then return i end
  end
  return #wrapped
end

-- Returns visual line index and pixel x for the cursor.
function AIChatView:get_cursor_visual_pos()
  local wrapped = self:get_wrapped_input()
  local li = self:get_cursor_line_idx(wrapped)
  local line = wrapped[li]
  local offset = math.max(0, math.min(self.cursor_pos - line.cstart, #line.text))
  return li, style.font:get_width(line.text:sub(1, offset))
end

function AIChatView:calc_input_height()
  local font = style.font
  local pad = style.padding.x
  local line_h = font:get_height() + 2
  local wrapped = self:get_wrapped_input()
  local num_lines = math.max(1, math.min(#wrapped, INPUT_MAX_LINES))
  return num_lines * line_h + pad
end

function AIChatView:draw_mention_popup(ox, bottom_y, w)
  if not self.mention_mode or #self.mention_filtered == 0 then
    self.mention_item_rects = {}
    return 0
  end
  local font  = style.font
  local pad   = style.padding.x
  local lh    = font:get_height() + 4
  local accent = style.accent or style.caret or style.text
  local n = #self.mention_filtered
  local pop_h = n * lh + 4
  local pop_y = bottom_y - pop_h - 2
  -- Background
  renderer.draw_rect(ox + pad / 2, pop_y, w - pad, pop_h,
    style.background2 or style.background)
  renderer.draw_rect(ox + pad / 2, pop_y, w - pad, 1, style.dim)
  self.mention_item_rects = {}
  for i, f in ipairs(self.mention_filtered) do
    local iy = pop_y + 2 + (i - 1) * lh
    local is_sel = (i == self.mention_sel)
    if is_sel then
      renderer.draw_rect(ox + pad / 2, iy, w - pad, lh,
        { accent[1], accent[2], accent[3], 30 })
    end
    local col = is_sel and accent or style.text
    renderer.draw_text(font, f.rel, ox + pad, iy + 2, col)
    self.mention_item_rects[i] = { x = ox + pad/2, y = iy, w = w - pad, h = lh }
  end
  return pop_h + 2
end

function AIChatView:draw_input(ox, oy, w)
  local font = style.font
  local pad = style.padding.x
  local accent = style.accent or style.caret or style.text
  local line_h = font:get_height() + 2

  local wrapped = self:get_wrapped_input()
  local num_lines = math.max(1, math.min(#wrapped, INPUT_MAX_LINES))
  local input_h = num_lines * line_h + pad

  renderer.draw_rect(ox, oy, w, input_h, style.background2)
  renderer.draw_rect(ox, oy, w, style.divider_size, style.dim)

  local text_x = ox + pad
  local text_y = oy + pad / 2

  -- Placeholder depends on tab
  local placeholder
  if self.current_tab == "agents" then
    placeholder = "New agent name..."
  else
    placeholder = "Type a message... (Shift+Enter for new line)"
  end

  if self.input_text ~= "" then
    for i = 1, num_lines do
      renderer.draw_text(font, wrapped[i].text, text_x, text_y + (i - 1) * line_h, style.text)
    end
    if self.input_focused and self.blink_timer < config.blink_period / 2 then
      local cl, cx = self:get_cursor_visual_pos()
      cl = math.min(cl, num_lines)
      renderer.draw_rect(text_x + cx, text_y + (cl - 1) * line_h,
        style.caret_width, font:get_height(), style.caret or accent)
    end
  else
    renderer.draw_text(font, placeholder, text_x, text_y, style.dim)
    if self.input_focused and self.blink_timer < config.blink_period / 2 then
      renderer.draw_rect(text_x, text_y, style.caret_width, font:get_height(),
        style.caret or accent)
    end
  end

  -- Token / context estimate (chat tab only)
  if self.current_tab == "chat" then
    local bytes = #self.input_text
    for _, kf in ipairs(knowledge_files) do if kf.enabled then bytes = bytes + kf.size end end
    for _, ef in ipairs(eks_files)       do if ef.enabled then bytes = bytes + (ef.size or 0) end end
    local tok = bytes / 4
    local tok_str = tok >= 1000
      and string.format("~%.1fk ctx", tok / 1000)
      or  string.format("~%d ctx", math.floor(tok))
    local tw = font:get_width(tok_str)
    renderer.draw_text(font, tok_str, ox + w - tw - pad, oy - line_h, style.dim)
  end

  -- /command completions popup (drawn just above the input box)
  local cmd_pop_h = self:draw_cmd_popup(ox, oy, w)
  -- @mention popup (stacked above cmd popup if both active)
  self:draw_mention_popup(ox, oy - cmd_pop_h, w)

  -- Send/Stop button (only on chat tab with text or running)
  self.send_btn_rect = nil
  if self.current_tab == "chat" and (self.input_text ~= "" or running_proc) then
    local btn_label = running_proc and "Stop" or "Send"
    local btn_w = font:get_width(btn_label) + pad
    local btn_x = ox + w - btn_w - pad / 2
    local btn_y = oy + input_h - line_h - 2
    local btn_h = line_h
    local btn_hov = (self.hovered_zone == "send" or self.hovered_zone == "stop")
    renderer.draw_rect(btn_x, btn_y, btn_w, btn_h,
      { (btn_hov and accent or style.dim)[1], (btn_hov and accent or style.dim)[2],
        (btn_hov and accent or style.dim)[3], 40 })
    renderer.draw_text(font, btn_label,
      btn_x + (btn_w - font:get_width(btn_label)) / 2,
      btn_y + (btn_h - font:get_height()) / 2,
      btn_hov and style.text or style.dim)
    self.send_btn_rect = { x = btn_x, y = btn_y, w = btn_w, h = btn_h }
  end

  self.input_rect = { x = ox, y = oy, w = w, h = input_h }
  return input_h
end


---------------------------------------------------------------------------
-- Main draw
-- Architecture: header + tab bar are FIXED (drawn in screen coords via
-- self.position).  Only the message/content area scrolls.  The input
-- field is also fixed at the bottom.  Fixed elements are drawn AFTER
-- scrollable content so their solid backgrounds cover any text that
-- drifts into the chrome area as the user scrolls.
---------------------------------------------------------------------------
function AIChatView:draw()
  self:draw_background(style.background)

  -- ox/oy shift with self.scroll (used for the scrollable content region).
  -- px/py are the fixed screen-space top-left of this view.
  local ox, oy = self:get_content_offset()
  local px, py = self.position.x, self.position.y
  local w      = self.size.x

  -- Heights of the two fixed chrome areas (deterministic; match draw_header / draw_tab_bar).
  local font      = style.font
  local pad       = style.padding.x
  local header_h  = font:get_height() + pad * 2
  local tab_h     = font:get_height() + pad
  local fixed_top = header_h + tab_h

  local no_input = (self.current_tab == "knowledge" or self.current_tab == "context" or self.current_tab == "decisions")
  local input_h  = no_input and 0 or self:calc_input_height()

  -- ── 1. Scrollable content (drawn first; painted over by chrome below) ──
  -- scroll_oy shifts with the View scroll so messages slide under the header.
  local scroll_oy = oy + fixed_top
  local content_y
  if self.current_tab == "chat" then
    content_y = self:draw_chat_tab(ox, scroll_oy, w, py + self.size.y - input_h)
  elseif self.current_tab == "agents" then
    content_y = self:draw_agents_tab(ox, scroll_oy, w, py + self.size.y - input_h)
  elseif self.current_tab == "knowledge" then
    content_y = self:draw_knowledge_tab(ox, scroll_oy, w, py + self.size.y)
  elseif self.current_tab == "context" then
    content_y = self:draw_context_tab(ox, scroll_oy, w, py + self.size.y)
  elseif self.current_tab == "decisions" then
    content_y = self:draw_adr_tab(ox, scroll_oy, w, py + self.size.y)
  end

  -- msg_h is scroll-invariant: both content_y and scroll_oy include the scroll offset,
  -- so their difference equals the intrinsic height of all rendered messages.
  local msg_h        = content_y and (content_y - scroll_oy) or 0
  local visible_msgs = self.size.y - fixed_top - input_h
  self.last_content_height = fixed_top + math.max(msg_h, visible_msgs) + input_h

  -- ── 2. Fixed chrome drawn ON TOP in screen coords ──
  -- Solid background rects in draw_header / draw_tab_bar / draw_input cover
  -- any scroll content that drifted into those regions.
  self:draw_header(px, py, w)
  self:draw_tab_bar(px, py + header_h, w)

  if not no_input then
    self:draw_input(px, py + self.size.y - input_h, w)
  else
    self.input_rect    = nil
    self.send_btn_rect = nil
  end

  self:draw_scrollbar()

  -- Dropdown menu floats on top of all content; drawn last so it occludes everything.
  self:draw_tab_dropdown_menu()
  -- Diff preview modal (on top of everything, including dropdown)
  self:draw_diff_preview()
end


---------------------------------------------------------------------------
-- Input handling
---------------------------------------------------------------------------
function AIChatView:mention_update()
  -- Recompute filtered file list from current query
  if not self.mention_mode then return end
  local query = self.input_text:sub(self.mention_at_pos + 2, self.cursor_pos):lower()
  local all = get_project_files()
  self.mention_filtered = {}
  for _, f in ipairs(all) do
    if query == "" or f.rel:lower():find(query, 1, true) or f.name:lower():find(query, 1, true) then
      table.insert(self.mention_filtered, f)
      if #self.mention_filtered >= 8 then break end
    end
  end
  self.mention_sel = math.max(1, math.min(self.mention_sel, #self.mention_filtered))
end

function AIChatView:mention_complete()
  -- Replace @query with @rel_path in input
  if not self.mention_mode or #self.mention_filtered == 0 then
    self.mention_mode = false; return
  end
  local chosen = self.mention_filtered[self.mention_sel]
  -- Splice: remove from @-position to cursor, insert @rel
  local insert = "@" .. chosen.rel
  local before  = self.input_text:sub(1, self.mention_at_pos)
  local after   = self.input_text:sub(self.cursor_pos + 1)
  self.input_text = before .. insert .. after
  self.cursor_pos = self.mention_at_pos + #insert
  self.mention_mode = false
  self.mention_filtered = {}
  core.redraw = true
end

function AIChatView:cmd_update()
  if not self.cmd_mode then return end
  local query = self.input_text:sub(1, self.cursor_pos):lower()
  self.cmd_filtered = {}
  for _, entry in ipairs(SLASH_COMMANDS) do
    if entry.cmd:find(query, 1, true) == 1 then
      table.insert(self.cmd_filtered, entry)
    end
  end
  self.cmd_sel = math.max(1, math.min(self.cmd_sel, math.max(1, #self.cmd_filtered)))
end

function AIChatView:cmd_complete()
  if not self.cmd_mode or #self.cmd_filtered == 0 then
    self.cmd_mode = false; return
  end
  local chosen = self.cmd_filtered[self.cmd_sel]
  -- Replace everything from start up to cursor with the command + space
  local after  = self.input_text:sub(self.cursor_pos + 1)
  self.input_text = chosen.cmd .. " " .. after:gsub("^%s+", "")
  self.cursor_pos = #chosen.cmd + 1
  self.cmd_mode = false
  self.cmd_filtered = {}
  core.redraw = true
end

function AIChatView:draw_cmd_popup(ox, bottom_y, w)
  if not self.cmd_mode or #self.cmd_filtered == 0 then
    self.cmd_item_rects = {}
    return 0
  end
  local font   = style.font
  local pad    = style.padding.x
  local lh     = font:get_height() + 4
  local accent = style.accent or style.caret or style.text
  local n      = #self.cmd_filtered
  local pop_h  = n * lh + 4
  local pop_y  = bottom_y - pop_h - 2
  renderer.draw_rect(ox + pad / 2, pop_y, w - pad, pop_h, style.background2 or style.background)
  renderer.draw_rect(ox + pad / 2, pop_y, w - pad, 1, style.dim)
  self.cmd_item_rects = {}
  for i, entry in ipairs(self.cmd_filtered) do
    local iy     = pop_y + 2 + (i - 1) * lh
    local is_sel = (i == self.cmd_sel)
    if is_sel then
      renderer.draw_rect(ox + pad / 2, iy, w - pad, lh, { accent[1], accent[2], accent[3], 30 })
    end
    local cmd_w = font:get_width(entry.cmd .. "  ")
    renderer.draw_text(font, entry.cmd, ox + pad, iy + 2, is_sel and accent or style.text)
    renderer.draw_text(font, entry.desc, ox + pad + cmd_w, iy + 2, style.dim)
    self.cmd_item_rects[i] = { x = ox + pad / 2, y = iy, w = w - pad, h = lh }
  end
  return pop_h + 2
end

function AIChatView:on_text_input(text)
  if not self.input_focused then return end
  local before = self.input_text:sub(1, self.cursor_pos)
  local after = self.input_text:sub(self.cursor_pos + 1)
  self.input_text = before .. text .. after
  self.cursor_pos = self.cursor_pos + #text
  -- /command completions (only when typing starts at position 0)
  if self.cmd_mode then
    if text:match("%s") then
      self.cmd_mode = false   -- space = done typing command; let it through
    else
      self:cmd_update()
    end
  elseif text == "/" and self.cursor_pos == 1 and self.current_tab == "chat" then
    self.cmd_mode = true
    self.cmd_sel  = 1
    self:cmd_update()
  end
  -- @mention detection
  if text == "@" and self.current_tab == "chat" then
    self.mention_mode   = true
    self.mention_at_pos = self.cursor_pos - 1  -- 0-based offset of '@'
    self.mention_sel    = 1
    self:mention_update()
  elseif self.mention_mode then
    -- Cancel on whitespace or if cursor moved behind '@'
    if text:match("%s") or self.cursor_pos <= self.mention_at_pos then
      self.mention_mode = false
    else
      self:mention_update()
    end
  end
  -- Typing cancels history navigation (user is now editing a new draft)
  if self.history_idx ~= nil then
    self.history_idx   = nil
    self.history_draft = ""
  end
  self.blink_timer = 0
  core.redraw = true
end


---------------------------------------------------------------------------
-- /explain: explain selected code in business terms using EKS context
---------------------------------------------------------------------------
function AIChatView:do_explain(hint)
  local agent   = get_active_agent()
  local eks_ctx = get_eks_context()

  -- Gather code to explain.
  -- Priority 1: active selection in the editor.
  -- Priority 2: ~60 lines around the cursor in the active file.
  local code_snippet = nil
  local location_hint = ""

  local view = core.active_view
  local doc  = view and view:is(DocView) and view.doc or nil

  if doc then
    local sel = get_selection_context()
    if sel and sel.text ~= "" then
      code_snippet   = sel.text
      location_hint  = "selected code"
    else
      -- Use doc.lines (array of strings, each ending with \n)
      local cursor_line = doc:get_selection()  -- returns l1, c1, l2, c2
      local l1 = cursor_line  -- get_selection returns l1 first
      local start_l = math.max(1,        l1 - 30)
      local end_l   = math.min(#doc.lines, l1 + 30)
      local lines   = {}
      for i = start_l, end_l do
        table.insert(lines, (doc.lines[i] or ""):gsub("\n$", ""))
      end
      code_snippet  = table.concat(lines, "\n")
      local fi      = get_active_file_context()
      location_hint = fi and (fi.filename .. " (around line " .. l1 .. ")") or ("line " .. l1)
    end
  end

  if not code_snippet or code_snippet:match("^%s*$") then
    add_message(agent, "system", "/explain: open a file and place the cursor (or select code) first.")
    return
  end

  local focus = hint ~= "" and ("\n\nFocus especially on: " .. hint) or ""
  local prompt = (eks_ctx ~= "" and eks_ctx or "") ..
    "Explain the following code in business terms — what it does, " ..
    "why it exists, which business rules or domain concepts it implements, " ..
    "and any concerns or risks from a product/engineering perspective." ..
    focus ..
    "\n\nLocation: " .. location_hint ..
    "\n\n```\n" .. code_snippet .. "\n```"

  local display = "/explain" .. (hint ~= "" and (" " .. hint) or "")
  add_message(agent, "user", display)
  local msg = add_message(agent, "assistant", "")
  streaming_msg = msg

  send_to_claude(agent, prompt, function(chunk)
    if streaming_msg then streaming_msg.text = streaming_msg.text .. chunk; chat_view.should_scroll_bottom = true; core.redraw = true end
  end, function(ok, err)
    streaming_msg = nil
    if not ok then msg.text = msg.text .. "\nError: " .. (err or "?") end
    core.redraw = true
  end)
end


function AIChatView:do_adr(title)
  local agent = get_active_agent()
  -- Build slug from title
  local slug = title:lower()
    :gsub("[%s_]+", "-")
    :gsub("[^%w%-]", "")
    :sub(1, 60)
  local date = os.date("%Y-%m-%d")
  local filename = date .. "-" .. slug .. ".md"

  -- Find project .glyph/adr/ dir
  local proj = core.project_directories and #core.project_directories > 0
    and core.project_directories[1].name or nil
  local adr_dir = proj and (proj .. PATHSEP .. ".glyph" .. PATHSEP .. "adr")

  -- Prompt Claude to write the ADR
  local eks_ctx = get_eks_context()
  local prompt = (eks_ctx ~= "" and eks_ctx or "") ..
    "Write an Architecture Decision Record (ADR) for the following decision:\n\n" ..
    "**" .. title .. "**\n\n" ..
    "Use this exact format:\n\n" ..
    "# ADR: " .. title .. "\n\n" ..
    "## Status\nProposed\n\n" ..
    "## Context\n[Why this decision needs to be made]\n\n" ..
    "## Decision\n[What was decided]\n\n" ..
    "## Consequences\n[What follows from this decision]\n\n" ..
    "## Alternatives Considered\n[Other options that were evaluated]\n\n" ..
    "Output ONLY the markdown content, no preamble."

  add_message(agent, "user", "/adr " .. title)
  local msg = add_message(agent, "assistant", "")
  streaming_msg = msg
  core.redraw = true

  send_to_claude(agent, prompt, function(chunk)
    if streaming_msg then streaming_msg.text = streaming_msg.text .. chunk; chat_view.should_scroll_bottom = true; core.redraw = true end
  end, function(ok, err)
    streaming_msg = nil
    if err then
      add_message(agent, "system", "ADR error: " .. err)
    elseif adr_dir and msg.text ~= "" then
      -- Save to .glyph/adr/<date>-<slug>.md
      local info = system.get_file_info(adr_dir)
      if not info then
        pcall(function()
          local parts = {}
          for seg in (adr_dir .. PATHSEP):gmatch("([^" .. PATHSEP .. "]+)" .. PATHSEP) do
            table.insert(parts, seg)
          end
          -- Try os.execute to create dir
          os.execute('mkdir "' .. adr_dir:gsub("/", "\\") .. '" 2>nul')
        end)
      end
      local path = adr_dir .. PATHSEP .. filename
      local f = io.open(path, "w")
      if f then
        f:write(msg.text); f:close()
        eks_scanned = false  -- force rescan to pick up new ADR
        add_message(agent, "system", "ADR saved: .glyph/adr/" .. filename)
      else
        add_message(agent, "system", "ADR generated but could not save to: " .. path)
      end
    end
    core.redraw = true
  end)
end

---------------------------------------------------------------------------
-- EKS Setup wizard: generates .glyph/ files using Claude
---------------------------------------------------------------------------
function AIChatView:do_eks_setup(description)
  local cur_proj = core.project_directories and #core.project_directories > 0
    and core.project_directories[1].name or nil
  if not cur_proj then
    core.log("EKS setup: no project open")
    return
  end

  local glyph_dir = cur_proj .. PATHSEP .. ".glyph"
  local proj_name = cur_proj:match("[/\\]([^/\\]+)$") or cur_proj

  -- Tell Claude what we need
  local prompt = string.format([[
You are helping set up an Enterprise Knowledge System (EKS) for a software project.
Generate FOUR Markdown files for the .glyph/ folder. Each file must start with a level-1 heading.

Project: %s
%s

Generate the following files. Separate each file with exactly this marker on its own line:
=== FILE: <filename> ===

Files to generate:
1. company.md   — Company overview: mission, values, industry, key stakeholders, business model
2. domain.md    — Technical domain: architecture, key systems, data flows, bounded contexts
3. standards.md — Engineering standards: code style, review process, testing requirements, tooling
4. team.md      — Team structure: roles, responsibilities, decision-making process, communication norms

Keep each file concise (100–200 words). Use Markdown headings and bullet lists.
Focus on information that helps an AI assistant understand the business and technical context.
]], proj_name, description ~= "" and ("Description: " .. description) or "")

  local agent = get_active_agent()
  local display = "/eks-setup" .. (description ~= "" and (" \"" .. description .. "\"") or "")
  add_message(agent, "user", display)
  streaming_msg = add_message(agent, "assistant", "")

  send_to_claude(agent, prompt, function(chunk)
    if streaming_msg then
      streaming_msg.text = streaming_msg.text .. chunk
      chat_view.should_scroll_bottom = true
      core.redraw = true
    end
  end, function(ok, err)
    if streaming_msg then
      local full = streaming_msg.text
      streaming_msg = nil
      if not ok then
        add_message(agent, "system", "EKS setup error: " .. (err or "?"))
        core.redraw = true
        save_history()
        return
      end
      -- Parse files from response using "=== FILE: <name> ===" markers
      pcall(function()
        os.execute('mkdir "' .. glyph_dir:gsub("/", "\\") .. '" 2>nul')
        local saved = {}
        for fname, content in full:gmatch("=== FILE: ([%w_%-%.]+%.md) ===\n(.-)\n?=== FILE:") do
          local path = glyph_dir .. PATHSEP .. fname
          local f = io.open(path, "w")
          if f then f:write(content:match("^%s*(.-)%s*$") .. "\n"); f:close(); table.insert(saved, fname) end
        end
        -- Last file (no trailing marker)
        local last_fname, last_content = full:match("=== FILE: ([%w_%-%.]+%.md) ===\n(.+)$")
        if last_fname and not saved[last_fname] then
          local path = glyph_dir .. PATHSEP .. last_fname
          local f = io.open(path, "w")
          if f then f:write(last_content:match("^%s*(.-)%s*$") .. "\n"); f:close(); table.insert(saved, last_fname) end
        end
        if #saved > 0 then
          add_message(agent, "system", "Saved: " .. table.concat(saved, ", ") .. " → .glyph/")
          eks_scanned = false  -- trigger rescan
        end
      end)
      save_history()
      core.redraw = true
    end
  end)
end


function AIChatView:send_current_input()
  local text = self.input_text
  if text == "" then return end

  -- Save to input history (deduplicate consecutive identical inputs)
  if self.input_history[#self.input_history] ~= text then
    table.insert(self.input_history, text)
    if #self.input_history > 200 then table.remove(self.input_history, 1) end
  end
  self.history_idx   = nil
  self.history_draft = ""

  if self.current_tab == "agents" then
    -- Create new agent
    local agent, idx = create_agent(text)
    set_active_agent(idx)
    self.input_text = ""
    self.cursor_pos = 0
    self.current_tab = "chat"  -- switch to chat
    core.redraw = true
    return
  end

  -- /review command: inject git diff into the prompt for Claude to review
  -- Usage: /review          → git diff HEAD (all uncommitted changes)
  --        /review staged   → git diff --staged (only staged changes)
  --        /review file     → git diff HEAD -- <current file>
  --        /review <msg>    → git diff HEAD, with extra instruction <msg>
  do
    local review_arg = text:match("^/review%s*(.*)$")
    if review_arg ~= nil then
      local cur_proj = core.project_directories and #core.project_directories > 0
        and core.project_directories[1].name or "."
      local git_args, extra_msg, display
      if review_arg == "staged" then
        git_args  = { "git", "-C", cur_proj, "diff", "--staged" }
        extra_msg = "Review my staged changes."
        display   = "/review staged"
      elseif review_arg == "file" then
        local fi  = get_active_file_context()
        local fname = fi and fi.filename or ""
        git_args  = { "git", "-C", cur_proj, "diff", "HEAD", "--", fname }
        extra_msg = "Review the diff for " .. (fname ~= "" and fname or "current file") .. "."
        display   = "/review file"
      else
        git_args  = { "git", "-C", cur_proj, "diff", "HEAD" }
        extra_msg = review_arg ~= "" and review_arg or "Review my changes and provide feedback."
        display   = "/review" .. (review_arg ~= "" and (" " .. review_arg) or "")
      end

      self.input_text = ""; self.cursor_pos = 0; self.mention_mode = false; self.cmd_mode = false
      core.redraw = true

      local agent = get_active_agent()
      agent.status = "fetching diff"
      core.redraw = true

      -- Run git non-blocking via process.start (no CMD window on Windows)
      core.add_thread(function()
        local ok, proc = pcall(process.start, git_args,
          { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_DISCARD })

        if not ok or not proc then
          agent.status = "idle"
          add_message(agent, "system", "/review: git not found or project is not a git repo.")
          core.redraw = true
          return
        end

        local chunks = {}
        while proc:running() do
          local chunk = proc:read_stdout(4096)
          if chunk and #chunk > 0 then
            table.insert(chunks, chunk)
          else
            coroutine.yield()
          end
        end
        -- Drain any data remaining in pipe after process exits
        repeat
          local chunk = proc:read_stdout(65536)
          if not chunk or #chunk == 0 then break end
          table.insert(chunks, chunk)
        until false

        agent.status = "idle"
        local diff_text = table.concat(chunks)

        if diff_text == "" then
          add_message(agent, "system", "/review: no changes detected (git diff returned empty).")
          core.redraw = true
          return
        end

        -- Show clean /review label in history; inject full diff only in the actual prompt
        local prompt_text = extra_msg .. "\n\n```diff\n" .. diff_text .. "\n```"
        local full_prompt = build_context_prefix(agent) .. prompt_text
        add_message(agent, "user", display)
        streaming_msg = add_message(agent, "assistant", "")
        send_to_claude(agent, full_prompt, function(chunk)
          if streaming_msg then streaming_msg.text = streaming_msg.text .. chunk; chat_view.should_scroll_bottom = true; core.redraw = true end
        end, function(ok2, err)
          if streaming_msg then
            if not ok2 then streaming_msg.text = streaming_msg.text .. "\nError: " .. (err or "?") end
            streaming_msg = nil
          end
          save_history(); core.redraw = true
        end)
      end)
      return
    end
  end

  -- /explain command: explain selected code in business terms using EKS context
  -- Usage: /explain           → explains current selection or visible code
  --        /explain <hint>    → explains with a business-domain focus hint
  if text:match("^/explain") then
    local hint = text:match("^/explain%s+(.+)$") or ""
    self.input_text = ""; self.cursor_pos = 0; self.mention_mode = false; self.cmd_mode = false
    core.redraw = true
    self:do_explain(hint)
    return
  end

  -- /adr command: create an Architecture Decision Record
  local adr_title = text:match("^/adr%s+(.+)$")
  if adr_title then
    self.input_text = ""
    self.cursor_pos = 0
    self.mention_mode = false
    self.cmd_mode = false
    core.redraw = true
    self:do_adr(adr_title)
    return
  end

  -- /eks-setup command: guided EKS file generation wizard
  -- Usage: /eks-setup  (optionally with a brief description of the project)
  --        /eks-setup "B2B SaaS for logistics, Zig backend, React frontend"
  do
    local eks_desc = text:match("^/eks%-setup%s*(.*)$")
    if eks_desc ~= nil then
      self.input_text = ""; self.cursor_pos = 0; self.mention_mode = false; self.cmd_mode = false
      core.redraw = true
      self:do_eks_setup(eks_desc)
      return
    end
  end

  -- Chat: expand @mentions → inject file content into prompt
  self.mention_mode = false
  self.cmd_mode = false
  local mentioned_parts = {}
  local display_text = text:gsub("(@[^%s@]+)", function(ref)
    local rel = ref:sub(2)  -- strip leading @
    -- Try to resolve against project root
    local cur_proj = core.project_directories and #core.project_directories > 0
      and core.project_directories[1].name or nil
    local full = cur_proj and (cur_proj .. PATHSEP .. rel:gsub("/", PATHSEP)) or nil
    if full then
      local f = io.open(full, "r")
      if f then
        local content = f:read("*a"); f:close()
        table.insert(mentioned_parts, "[File: " .. rel .. "]\n```\n" .. content .. "\n```")
        return ref  -- keep @mention in display text
      end
    end
    return ref  -- file not found, keep as-is
  end)
  local mention_ctx = #mentioned_parts > 0
    and ("\n\n[Referenced files]\n" .. table.concat(mentioned_parts, "\n\n"))
    or ""
  local agent = get_active_agent()
  local prompt = build_context_prefix(agent) .. display_text .. mention_ctx
  add_message(agent, "user", display_text)
  self.input_text = ""
  self.cursor_pos = 0
  core.redraw = true

  streaming_msg = add_message(agent, "assistant", "")

  send_to_claude(agent, prompt, function(chunk)
    if streaming_msg then
      streaming_msg.text = streaming_msg.text .. chunk
      chat_view.should_scroll_bottom = true
      core.redraw = true
    end
  end, function(ok, err)
    if err then
      if streaming_msg and streaming_msg.text == "" then
        streaming_msg.text = "Error: " .. err
      else
        add_message(agent, "system", "Error: " .. err)
      end
    end
    streaming_msg = nil
    core.redraw = true
  end)
end


function AIChatView:on_mouse_pressed(button, x, y, clicks)
  local caught = AIChatView.super.on_mouse_pressed(self, button, x, y, clicks)
  if caught then return caught end

  -- Diff preview modal intercepts all clicks
  if self.diff_preview then
    local dp = self.diff_preview
    local function hit(r) return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h end
    if hit(dp.confirm_rect) then
      self:do_apply(dp.apply_cb)
      self.diff_preview = nil
      core.redraw = true
      return true
    elseif hit(dp.cancel_rect) then
      self.diff_preview = nil
      core.redraw = true
      return true
    end
    -- Any other click while modal is open: swallow (keep modal visible)
    return true
  end

  -- ADR rows: click opens file in editor
  for _, rect in ipairs(self.adr_rects or {}) do
    if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
      if rect.path then
        pcall(function()
          core.root_view:open_doc(core.open_doc(rect.path))
        end)
      end
      core.redraw = true
      return true
    end
  end

  -- /command popup click
  for i, rect in ipairs(self.cmd_item_rects or {}) do
    if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
      self.cmd_sel = i
      self:cmd_complete()
      return true
    end
  end

  -- @mention popup click
  for i, rect in ipairs(self.mention_item_rects or {}) do
    if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
      self.mention_sel = i
      self:mention_complete()
      return true
    end
  end

  -- Code block Copy / Apply buttons
  for _, cb in ipairs(self.code_copy_rects or {}) do
    local r = cb.rect
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      if cb.action == "copy" then
        system.set_clipboard(cb.content)
        core.log("Copied code block to clipboard.")
      elseif cb.action == "apply" or cb.action == "apply_file" then
        -- Open diff preview instead of applying directly
        self:open_diff_preview(cb)
      end
      core.redraw = true
      return true
    end
  end

  -- Header buttons
  for _, btn in ipairs(self.header_btns or {}) do
    if x >= btn.x and x < btn.x + btn.w and y >= btn.y and y < btn.y + btn.h then
      if btn.cmd == "export" then
        self:export_to_markdown()
      elseif btn.cmd == "new" then
        local agent, idx = create_agent()
        set_active_agent(idx)
        self.input_text = ""
        self.cursor_pos = 0
        self.current_tab = "chat"
        core.redraw = true
      elseif btn.cmd == "close" then
        self.visible = false
        core.redraw = true
      end
      return true
    end
  end

  -- Dropdown menu items (checked before the trigger button so the menu
  -- items can be clicked even if they overlap the button area)
  for _, item in ipairs(self.tab_dropdown_item_rects or {}) do
    if x >= item.x and x < item.x + item.w and y >= item.y and y < item.y + item.h then
      self.current_tab   = item.id
      self.dropdown_open = false
      self.input_text    = ""
      self.cursor_pos    = 0
      core.redraw = true
      return true
    end
  end

  -- Dropdown trigger button — toggle open/closed
  if self.tab_dropdown_rect then
    local r = self.tab_dropdown_rect
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      self.dropdown_open = not self.dropdown_open
      core.redraw = true
      return true
    end
  end

  -- Click anywhere outside the dropdown → close it
  if self.dropdown_open then
    self.dropdown_open = false
    core.redraw = true
  end

  -- Login button
  if self.login_btn_rect then
    local r = self.login_btn_rect
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      do_login(); return true
    end
  end

  -- Refresh auth button
  if self.refresh_auth_rect then
    local r = self.refresh_auth_rect
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      auth_checked = false; auth_info = nil
      check_auth_status()
      core.redraw = true
      return true
    end
  end

  -- Create .glyph/ structure
  if self.create_glyph_rect then
    local r = self.create_glyph_rect
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      create_glyph_structure()
      core.redraw = true
      return true
    end
  end

  -- Create knowledge/ folder
  if self.create_folder_rect then
    local r = self.create_folder_rect
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      create_knowledge_folder()
      core.redraw = true
      return true
    end
  end

  -- Refresh all knowledge + EKS
  if self.refresh_rect then
    local r = self.refresh_rect
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      knowledge_scanned = false; eks_scanned = false
      scan_knowledge(); scan_eks()
      core.redraw = true
      return true
    end
  end

  -- EKS Edit buttons
  for idx, rect in pairs(self.eks_edit_rects or {}) do
    if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
      local ef = eks_files[idx]
      if ef and ef.path then
        pcall(function() core.root_view:open_doc(core.open_doc(ef.path)) end)
      end
      core.redraw = true
      return true
    end
  end

  -- EKS New file button
  if self.eks_new_rect then
    local r = self.eks_new_rect
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      self:eks_new_file()
      return true
    end
  end

  -- EKS items: [x]/[ ] checkbox toggles; name click opens file in editor
  for idx, rect in pairs(self.eks_rects or {}) do
    if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
      local cb = self.eks_cb_rects and self.eks_cb_rects[idx]
      if cb and x >= cb.x and x < cb.x + cb.w then
        eks_files[idx].enabled = not eks_files[idx].enabled
      else
        -- Only open file if not clicking the Edit button
        local eb = self.eks_edit_rects and self.eks_edit_rects[idx]
        if not (eb and x >= eb.x and x < eb.x + eb.w) then
          local ef = eks_files[idx]
          if ef and ef.path then
            pcall(function()
              core.root_view:open_doc(core.open_doc(ef.path))
            end)
          end
        end
      end
      core.redraw = true
      return true
    end
  end

  -- Agent delete buttons
  for idx, rect in pairs(self.agent_del_rects) do
    if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
      delete_agent(idx)
      core.redraw = true
      return true
    end
  end

  -- Agent list items (click to activate + switch to chat)
  for idx, rect in pairs(self.agent_rects) do
    if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
      set_active_agent(idx)
      self.current_tab = "chat"
      self.input_text = ""
      self.cursor_pos = 0
      core.redraw = true
      return true
    end
  end

  -- Knowledge items: [x]/[ ] checkbox toggles; rest of row opens file in editor
  for idx, rect in pairs(self.knowledge_rects) do
    if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
      local cb = self.knowledge_cb_rects and self.knowledge_cb_rects[idx]
      if cb and x >= cb.x and x < cb.x + cb.w then
        knowledge_files[idx].enabled = not knowledge_files[idx].enabled
      else
        local kf = knowledge_files[idx]
        if kf and kf.path then
          pcall(function()
            core.root_view:open_doc(core.open_doc(kf.path))
          end)
        end
      end
      core.redraw = true
      return true
    end
  end

  -- Send/Stop button
  if self.send_btn_rect then
    local r = self.send_btn_rect
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      if running_proc then
        running_proc:terminate()
        running_proc = nil
        if running_agent then running_agent.status = "idle"; running_agent = nil end
        if streaming_msg then
          streaming_msg.text = streaming_msg.text .. "\n[Stopped]"
          streaming_msg = nil
        end
      else
        self:send_current_input()
      end
      core.redraw = true
      return true
    end
  end

  -- Click on input area: focus and position cursor on correct visual line
  if self.input_rect then
    local r = self.input_rect
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      self.input_focused = true
      self.blink_timer = 0
      local font = style.font
      local pad = style.padding.x
      local line_h = font:get_height() + 2
      local text_x = r.x + pad
      local text_y = r.y + pad / 2
      -- Which visual line was clicked?
      local li = math.floor((y - text_y) / line_h) + 1
      local wrapped = self:get_wrapped_input()
      li = math.max(1, math.min(li, #wrapped))
      local line = wrapped[li]
      local char_off = line_x_to_char(font, line.text, x - text_x)
      self.cursor_pos = line.cstart + char_off
      core.redraw = true
      return true
    end
  end

  -- Click elsewhere: unfocus
  self.input_focused = false
  core.redraw = true
end


function AIChatView:on_mouse_wheel(y, ...)
  if self.diff_preview and self.diff_preview.diff then
    local clh = (style.code_font or style.font):get_height() + 1
    self.diff_preview.scroll_y = self.diff_preview.scroll_y - y * clh * 3
    core.redraw = true
    return true
  end
  return AIChatView.super.on_mouse_wheel(self, y, ...)
end


function AIChatView:on_mouse_moved(px, py, ...)
  AIChatView.super.on_mouse_moved(self, px, py, ...)
  self.hovered_zone = nil

  -- Header buttons
  for _, btn in ipairs(self.header_btns or {}) do
    if px >= btn.x and px < btn.x + btn.w and py >= btn.y and py < btn.y + btn.h then
      self.hovered_zone = "hdr_" .. btn.cmd
      self.cursor = "hand"; return
    end
  end

  -- Dropdown menu items (checked before the trigger so they take priority)
  for _, item in ipairs(self.tab_dropdown_item_rects or {}) do
    if px >= item.x and px < item.x + item.w and py >= item.y and py < item.y + item.h then
      self.hovered_zone = "tab_dropdown_item_" .. item.id
      self.cursor = "hand"; return
    end
  end

  -- Dropdown trigger button
  if self.tab_dropdown_rect then
    local r = self.tab_dropdown_rect
    if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then
      self.hovered_zone = "tab_dropdown_btn"
      self.cursor = "hand"; return
    end
  end

  -- Login
  if self.login_btn_rect then
    local r = self.login_btn_rect
    if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then
      self.hovered_zone = "login"; self.cursor = "hand"; return
    end
  end

  -- Refresh auth
  if self.refresh_auth_rect then
    local r = self.refresh_auth_rect
    if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then
      self.hovered_zone = "refresh_auth"; self.cursor = "hand"; return
    end
  end

  -- Create .glyph/
  if self.create_glyph_rect then
    local r = self.create_glyph_rect
    if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then
      self.hovered_zone = "create_glyph"; self.cursor = "hand"; return
    end
  end

  -- Create folder
  if self.create_folder_rect then
    local r = self.create_folder_rect
    if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then
      self.hovered_zone = "create_folder"; self.cursor = "hand"; return
    end
  end

  -- EKS Edit buttons
  for idx, rect in pairs(self.eks_edit_rects or {}) do
    if px >= rect.x and px < rect.x + rect.w and py >= rect.y and py < rect.y + rect.h then
      self.hovered_zone = "eks_edit_" .. idx; self.cursor = "hand"; return
    end
  end

  -- EKS New file button
  if self.eks_new_rect then
    local r = self.eks_new_rect
    if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then
      self.hovered_zone = "eks_new"; self.cursor = "hand"; return
    end
  end

  -- EKS items: distinguish checkbox hover vs filename hover
  for idx, rect in pairs(self.eks_rects or {}) do
    if px >= rect.x and px < rect.x + rect.w and py >= rect.y and py < rect.y + rect.h then
      local cb = self.eks_cb_rects and self.eks_cb_rects[idx]
      if cb and px >= cb.x and px < cb.x + cb.w then
        self.hovered_zone = "eks_" .. idx
      else
        self.hovered_zone = "eks_open_" .. idx
      end
      self.cursor = "hand"; return
    end
  end

  -- Refresh
  if self.refresh_rect then
    local r = self.refresh_rect
    if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then
      self.hovered_zone = "refresh_knowledge"; self.cursor = "hand"; return
    end
  end

  -- Agent delete buttons
  for idx, rect in pairs(self.agent_del_rects or {}) do
    if px >= rect.x and px < rect.x + rect.w and py >= rect.y and py < rect.y + rect.h then
      self.hovered_zone = "agent_del_" .. idx; self.cursor = "hand"; return
    end
  end

  -- Agent list
  for idx, rect in pairs(self.agent_rects or {}) do
    if px >= rect.x and px < rect.x + rect.w and py >= rect.y and py < rect.y + rect.h then
      self.hovered_zone = "agent_" .. idx; self.cursor = "hand"; return
    end
  end

  -- Knowledge items: distinguish checkbox hover vs filename hover
  for idx, rect in pairs(self.knowledge_rects or {}) do
    if px >= rect.x and px < rect.x + rect.w and py >= rect.y and py < rect.y + rect.h then
      local cb = self.knowledge_cb_rects and self.knowledge_cb_rects[idx]
      if cb and px >= cb.x and px < cb.x + cb.w then
        self.hovered_zone = "knowledge_" .. idx
      else
        self.hovered_zone = "knowledge_open_" .. idx
      end
      self.cursor = "hand"; return
    end
  end

  -- ADR rows (Decisions tab)
  for _, rect in ipairs(self.adr_rects or {}) do
    if px >= rect.x and px < rect.x + rect.w and py >= rect.y and py < rect.y + rect.h then
      self.hovered_zone = "adr_" .. (rect.path or "")
      self.cursor = "hand"; return
    end
  end

  -- Send button
  if self.send_btn_rect then
    local r = self.send_btn_rect
    if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then
      self.hovered_zone = running_proc and "stop" or "send"
      self.cursor = "hand"; return
    end
  end

  -- Input area
  if self.input_rect then
    local r = self.input_rect
    if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then
      self.cursor = "ibeam"; return
    end
  end

  self.cursor = "arrow"
end


---------------------------------------------------------------------------
-- Plugin setup
---------------------------------------------------------------------------
chat_view = AIChatView()
local node = core.root_view:get_active_node()
chat_view.node = node:split("right", chat_view, {x = true}, true)
log("aichat ready")
core.log("AI Chat plugin loaded")


local function toggle_chat()
  chat_view.visible = not chat_view.visible
  if chat_view.visible then
    chat_view.target_size = config.plugins.aichat.size
    core.set_active_view(chat_view)
    chat_view.input_focused = true
  end
  core.redraw = true
end

local function ensure_chat_visible()
  if not chat_view.visible then
    chat_view.visible = true
    chat_view.target_size = config.plugins.aichat.size
  end
  return chat_view
end


---------------------------------------------------------------------------
-- UTF-8 cursor movement helpers
---------------------------------------------------------------------------
-- Move cursor_pos (0-indexed byte offset) left by one UTF-8 character.
local function utf8_step_left(str, pos)
  if pos <= 0 then return 0 end
  local ok, p = pcall(utf8.offset, str, -1, pos + 1)
  if ok and p then return p - 1 end
  -- Fallback: walk back byte by byte skipping continuation bytes (10xxxxxx)
  local i = pos
  repeat i = i - 1 until i <= 0 or (str:byte(i) or 0) & 0xC0 ~= 0x80
  return math.max(0, i - 1)
end

-- Move cursor_pos (0-indexed byte offset) right by one UTF-8 character.
local function utf8_step_right(str, pos)
  if pos >= #str then return #str end
  local ok, p = pcall(utf8.offset, str, 2, pos + 1)
  if ok and p then return math.min(#str, p - 1) end
  -- Fallback: walk forward byte by byte skipping continuation bytes
  local i = pos + 2
  while i <= #str and (str:byte(i) or 0) & 0xC0 == 0x80 do i = i + 1 end
  return math.min(#str, i - 1)
end

---------------------------------------------------------------------------
-- Input field key commands
---------------------------------------------------------------------------
command.add(function()
  return core.active_view:is(AIChatView) and core.active_view.input_focused
end, {
  ["ai:submit"] = function()
    if chat_view.cmd_mode then
      chat_view:cmd_complete()
    elseif chat_view.mention_mode then
      chat_view:mention_complete()
    else
      chat_view:send_current_input()
    end
  end,
  ["ai:newline"] = function()
    if chat_view.cmd_mode then
      chat_view:cmd_complete(); return
    end
    if chat_view.mention_mode then
      chat_view:mention_complete(); return
    end
    local before = chat_view.input_text:sub(1, chat_view.cursor_pos)
    local after = chat_view.input_text:sub(chat_view.cursor_pos + 1)
    chat_view.input_text = before .. "\n" .. after
    chat_view.cursor_pos = chat_view.cursor_pos + 1
    chat_view.blink_timer = 0
    core.redraw = true
  end,
  ["ai:backspace"] = function()
    if chat_view.cursor_pos > 0 then
      -- Move left by one full UTF-8 character to find the deletion start
      local new_pos = utf8_step_left(chat_view.input_text, chat_view.cursor_pos)
      local before = chat_view.input_text:sub(1, new_pos)
      local after = chat_view.input_text:sub(chat_view.cursor_pos + 1)
      chat_view.input_text = before .. after
      chat_view.cursor_pos = new_pos
      -- Cancel cmd_mode if input no longer starts with '/'
      if chat_view.cmd_mode then
        if chat_view.cursor_pos == 0 or chat_view.input_text:sub(1,1) ~= "/" then
          chat_view.cmd_mode = false
        else
          chat_view:cmd_update()
        end
      end
      -- Cancel mention if we backspaced past '@'
      if chat_view.mention_mode and chat_view.cursor_pos <= chat_view.mention_at_pos then
        chat_view.mention_mode = false
      elseif chat_view.mention_mode then
        chat_view:mention_update()
      end
      chat_view.blink_timer = 0
      core.redraw = true
    end
  end,
  ["ai:delete-word"] = function()
    if chat_view.cursor_pos > 0 then
      local before = chat_view.input_text:sub(1, chat_view.cursor_pos)
      local after = chat_view.input_text:sub(chat_view.cursor_pos + 1)
      before = before:gsub("[%w_]+%s*$", ""):gsub("%S+%s*$", "")
      chat_view.input_text = before .. after
      chat_view.cursor_pos = #before
      chat_view.blink_timer = 0
      core.redraw = true
    end
  end,
  ["ai:cursor-left"] = function()
    if chat_view.cursor_pos > 0 then
      chat_view.cursor_pos = utf8_step_left(chat_view.input_text, chat_view.cursor_pos)
      chat_view.blink_timer = 0; core.redraw = true
    end
  end,
  ["ai:cursor-right"] = function()
    if chat_view.cursor_pos < #chat_view.input_text then
      chat_view.cursor_pos = utf8_step_right(chat_view.input_text, chat_view.cursor_pos)
      chat_view.blink_timer = 0; core.redraw = true
    end
  end,
  ["ai:cursor-up"] = function()
    if chat_view.cmd_mode then
      chat_view.cmd_sel = math.max(1, chat_view.cmd_sel - 1)
      core.redraw = true; return
    end
    if chat_view.mention_mode then
      chat_view.mention_sel = math.max(1, chat_view.mention_sel - 1)
      core.redraw = true; return
    end
    -- History navigation: trigger when on the first visual line
    local wrapped = chat_view:get_wrapped_input()
    local li = chat_view:get_cursor_line_idx(wrapped)
    if li <= 1 and #chat_view.input_history > 0 then
      if chat_view.history_idx == nil then
        -- Save draft and start navigating from end of history
        chat_view.history_draft = chat_view.input_text
        chat_view.history_idx   = #chat_view.input_history
      elseif chat_view.history_idx > 1 then
        chat_view.history_idx = chat_view.history_idx - 1
      end
      local entry = chat_view.input_history[chat_view.history_idx]
      chat_view.input_text  = entry
      chat_view.cursor_pos  = #entry
      chat_view.blink_timer = 0; core.redraw = true
      return
    end
    if li <= 1 then return end
    local font = style.font
    local cur_line = wrapped[li]
    local offset = math.max(0, math.min(chat_view.cursor_pos - cur_line.cstart, #cur_line.text))
    local cur_x = font:get_width(cur_line.text:sub(1, offset))
    local prev = wrapped[li - 1]
    chat_view.cursor_pos = prev.cstart + line_x_to_char(font, prev.text, cur_x)
    chat_view.blink_timer = 0; core.redraw = true
  end,
  ["ai:cursor-down"] = function()
    if chat_view.cmd_mode then
      chat_view.cmd_sel = math.min(#chat_view.cmd_filtered, chat_view.cmd_sel + 1)
      core.redraw = true; return
    end
    if chat_view.mention_mode then
      chat_view.mention_sel = math.min(#chat_view.mention_filtered, chat_view.mention_sel + 1)
      core.redraw = true; return
    end
    -- History navigation: ↓ goes forward or restores draft
    if chat_view.history_idx ~= nil then
      if chat_view.history_idx < #chat_view.input_history then
        chat_view.history_idx = chat_view.history_idx + 1
        local entry = chat_view.input_history[chat_view.history_idx]
        chat_view.input_text  = entry
        chat_view.cursor_pos  = #entry
      else
        -- End of history: restore draft
        chat_view.input_text  = chat_view.history_draft
        chat_view.cursor_pos  = #chat_view.history_draft
        chat_view.history_idx = nil
      end
      chat_view.blink_timer = 0; core.redraw = true
      return
    end
    local wrapped = chat_view:get_wrapped_input()
    local li = chat_view:get_cursor_line_idx(wrapped)
    if li >= #wrapped then return end
    local font = style.font
    local cur_line = wrapped[li]
    local offset = math.max(0, math.min(chat_view.cursor_pos - cur_line.cstart, #cur_line.text))
    local cur_x = font:get_width(cur_line.text:sub(1, offset))
    local nxt = wrapped[li + 1]
    chat_view.cursor_pos = nxt.cstart + line_x_to_char(font, nxt.text, cur_x)
    chat_view.blink_timer = 0; core.redraw = true
  end,
  ["ai:cursor-home"] = function()
    -- Go to start of visual line
    local wrapped = chat_view:get_wrapped_input()
    local li = chat_view:get_cursor_line_idx(wrapped)
    chat_view.cursor_pos = wrapped[li].cstart
    chat_view.blink_timer = 0; core.redraw = true
  end,
  ["ai:cursor-end"] = function()
    -- Go to end of visual line
    local wrapped = chat_view:get_wrapped_input()
    local li = chat_view:get_cursor_line_idx(wrapped)
    local line = wrapped[li]
    chat_view.cursor_pos = line.cstart + #line.text
    chat_view.blink_timer = 0; core.redraw = true
  end,
  ["ai:escape"] = function()
    if chat_view.diff_preview then
      chat_view.diff_preview = nil; core.redraw = true
    elseif chat_view.dropdown_open then
      chat_view.dropdown_open = false; core.redraw = true
    elseif chat_view.cmd_mode then
      chat_view.cmd_mode = false; core.redraw = true
    elseif chat_view.mention_mode then
      chat_view.mention_mode = false; core.redraw = true
    else
      chat_view.input_focused = false; core.redraw = true
    end
  end,
  ["ai:select-all"] = function()
    chat_view.cursor_pos = #chat_view.input_text; core.redraw = true
  end,
  ["ai:paste"] = function()
    local text = system.get_clipboard()
    if text then
      text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
      chat_view:on_text_input(text)
    end
  end,
})

keymap.add {
  ["shift+return"]   = "ai:newline",
  ["return"]         = "ai:submit",
  ["backspace"]      = "ai:backspace",
  ["ctrl+backspace"] = "ai:delete-word",
  ["left"]           = "ai:cursor-left",
  ["right"]          = "ai:cursor-right",
  ["up"]             = "ai:cursor-up",
  ["down"]           = "ai:cursor-down",
  ["home"]           = "ai:cursor-home",
  ["end"]            = "ai:cursor-end",
  ["escape"]         = "ai:escape",
  ["ctrl+a"]         = "ai:select-all",
  ["ctrl+v"]         = "ai:paste",
}


---------------------------------------------------------------------------
-- Global commands
---------------------------------------------------------------------------
command.add(nil, {
  ["ai:toggle-chat"] = toggle_chat,
  ["ai:new-conversation"] = function()
    local agent, idx = create_agent()
    set_active_agent(idx)
    local view = ensure_chat_visible()
    view.current_tab = "chat"
    view.input_text = ""
    view.cursor_pos = 0
    core.set_active_view(view)
    view.input_focused = true
    core.redraw = true
  end,
  ["ai:focus-input"] = function()
    local view = ensure_chat_visible()
    core.set_active_view(view)
    view.current_tab = "chat"
    view.input_focused = true
    view.blink_timer = 0
    core.redraw = true
  end,
  ["ai:ask-with-context"] = function()
    local view = ensure_chat_visible()
    core.set_active_view(view)
    view.current_tab = "chat"
    view.input_focused = true
    view.blink_timer = 0
    local s = get_selection_context()
    local f = get_active_file_context()
    if s then
      view.input_text = "[sel:" .. s.line1 .. "-" .. s.line2 .. "] "
    elseif f then
      view.input_text = "[" .. f.filename .. "] "
    end
    view.cursor_pos = #view.input_text
    core.redraw = true
  end,
  ["ai:stop"] = function()
    if running_proc then
      running_proc:terminate()
      running_proc = nil
      if running_agent then running_agent.status = "idle"; running_agent = nil end
      if streaming_msg then
        streaming_msg.text = streaming_msg.text .. "\n[Stopped]"
        streaming_msg = nil
      end
      core.redraw = true
    end
  end,
  ["ai:login"] = do_login,
  ["ai:show-agents"] = function()
    local view = ensure_chat_visible()
    core.set_active_view(view)
    view.current_tab = "agents"
    core.redraw = true
  end,
  ["ai:show-knowledge"] = function()
    local view = ensure_chat_visible()
    core.set_active_view(view)
    view.current_tab = "knowledge"
    core.redraw = true
  end,
})

keymap.add {
  ["ctrl+."]       = "ai:focus-input",
  ["ctrl+shift+."] = "ai:toggle-chat",
  ["ctrl+shift+n"] = "ai:new-conversation",
}

---------------------------------------------------------------------------
-- Status bar: EKS active context badges
-- Shows [Company] [Domain] [Team] etc. for each enabled EKS file.
-- Click on a badge opens the corresponding file.
---------------------------------------------------------------------------
local StatusView = require "core.statusview"

-- Badge click detection: populated during on_draw (real pass), read in on_click.
local eks_badge_rects = {}  -- { x1, x2, idx }

core.status_view:add_item({
  name      = "aichat:eks-badges",
  alignment = StatusView.Item.LEFT,
  tooltip   = "EKS active context — click to open file",
  -- get_item returns empty; we use on_draw for custom rendering
  get_item  = function() return {} end,

  on_draw = function(x, y, h, hovered, calc_only)
    local pad   = math.floor(style.padding.x * 0.7)
    local vpad  = 3
    local total_w = pad  -- leading space

    local new_rects = {}
    for i, ef in ipairs(eks_files) do
      if ef.enabled then
        local label = ef.label
        local tw = style.font:get_width(label) + pad * 2
        local bx = x + total_w

        if not calc_only then
          -- Badge background color: blue for core layers, purple for ADR
          local bg
          if ef.layer == "adr" then
            bg = { 110, 60, 170, 210 }
          elseif ef.source == "global" then
            bg = { 40, 100, 180, 210 }
          else
            bg = { 30, 130, 100, 210 }
          end
          renderer.draw_rect(bx, y + vpad, tw, h - vpad * 2, bg)
          local text_y = y + math.floor((h - style.font:get_height()) / 2)
          renderer.draw_text(style.font, label, bx + pad, text_y, style.background)
          table.insert(new_rects, { x1 = bx, x2 = bx + tw, idx = i })
        end

        total_w = total_w + tw + pad
      end
    end

    if not calc_only then
      eks_badge_rects = new_rects
    end

    -- Return 0 if nothing to show (predicate should prevent this, but be safe)
    if total_w <= pad then return 0 end
    return total_w
  end,

  -- Called when user clicks anywhere on this item; determine which badge by x pos
  command = function(button, x, y)
    if button ~= "left" then return end
    for _, rect in ipairs(eks_badge_rects) do
      if x >= rect.x1 and x < rect.x2 then
        local ef = eks_files[rect.idx]
        if ef then
          core.try(function()
            core.root_view:open_doc(core.open_doc(ef.path))
          end)
          return
        end
      end
    end
  end,

  predicate = function()
    if not eks_scanned then return false end
    for _, ef in ipairs(eks_files) do
      if ef.enabled then return true end
    end
    return false
  end,
})


-- Global hook for other plugins (e.g. selection_actions.lua)
-- glyph_ai_send(prefix, code_snippet, auto_send)
_G.glyph_ai_send = function(prefix, code_snippet, auto_send)
  ensure_chat_visible()
  local text = prefix or ""
  if code_snippet and code_snippet ~= "" then
    text = text .. "\n\n```\n" .. code_snippet:gsub("\n+$", "") .. "\n```"
  end
  chat_view.input_text  = text
  chat_view.cursor_pos  = #text
  chat_view.input_focused = true
  chat_view.current_tab = "chat"
  core.set_active_view(chat_view)
  core.redraw = true
  if auto_send then
    chat_view:send_current_input()
  end
end

return {
  view = AIChatView,
  chat_view = chat_view,
  toggle_chat = toggle_chat,
}
