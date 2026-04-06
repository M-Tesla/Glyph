# Glyph

An IDE built on [Lite-XL](https://github.com/lite-xl/lite-xl) with a rewritten Zig backend and a set of Lua plugins focused on keeping business context inside the editor.

The main idea is **business-driven design**: the editor maintains a structured knowledge base (company, domain, standards, team) that gets injected into every AI conversation automatically. No more re-explaining your architecture every session.

---

## What it is

- Lite-XL core, with SDL3 + FreeType rendered by Zig
- AI Chat panel powered by the Claude Code CLI — no API key needed
- EKS (Enterprise Knowledge System): versioned `.glyph/` files that travel with your repo
- Architecture Decision Records: first-class ADR support with AI-assisted creation
- Full LSP client (completions, hover, go-to-def, references, rename, diagnostics)
- Git gutter markers and branch indicator
- Ghost text inline completions (`Ctrl+I`)
- Integrated terminal (`Ctrl+J`)
- Multi-agent conversations
- ~30ms cold startup, ~128MB RAM

---

## Requirements

- Zig 0.15.2
- The [Claude Code CLI](https://github.com/anthropics/claude-code): `npm install -g @anthropic-ai/claude-code`, then `claude auth login`
- Git in PATH (optional — for gutter markers)
- An LSP binary in PATH (optional — e.g. `zls` for Zig)

Windows 11 x64 and Linux x86-64 are supported.

---

## Building

```bash
git clone https://github.com/your-org/glyph.git
cd glyph
zig build                            # debug
zig build -Doptimize=ReleaseSafe     # optimized
```

SDL3, FreeType, Lua 5.4, and PCRE2 are fetched and compiled on first build.

Output: `zig-out/bin/glyph` + `zig-out/bin/data/`

---

## Installation

No installer. Extract the release archive and run the binary. User data is stored in `user/` next to the executable.

```bash
# Linux
./glyph /path/to/project

# Windows
glyph.exe C:\path\to\project
```

---

## Enterprise Knowledge System (EKS)

EKS lives in `.glyph/` inside your project:

```
your-project/
└── .glyph/
    ├── company.md     what your company does, business model
    ├── domain.md      bounded contexts, system architecture
    ├── standards.md   engineering standards, tooling decisions
    ├── team.md        team structure, decision norms
    └── adr/
        ├── 2025-01-15-use-postgresql.md
        └── 2025-03-10-deprecate-rest-for-grpc.md
```

Every AI message gets these files prepended automatically. Commit `.glyph/` to git — the whole team shares the same context from day one.

There's also a global layer at `~/.glyph/` for personal preferences that apply across all projects.

### Bootstrap with /eks-setup

```
/eks-setup
```

The AI interviews you and writes all four files into `.glyph/` immediately.

---

## Architecture Decision Records

ADRs are stored in `.glyph/adr/` and injected into every conversation. To create one:

```
/adr
```

The AI drafts it using your existing domain and standards context. The **Decisions** tab in the chat panel shows a timeline of all records.

---

## AI Chat

`Ctrl+Shift+.` toggles the panel. `Ctrl+.` focuses the input.

**Tabs:**
- **Chat** — main conversation, streams in real time
- **Agents** — multiple independent agents, each with their own history
- **Knowledge** — toggle which `.glyph/` files are included in context
- **Context** — shows exactly what gets prepended to each message
- **Decisions** — ADR timeline

**File mentions:** type `@filename` to inject file contents inline.

**Slash commands:**
- `/explain` — explain selected text in plain terms
- `/review` — review `git diff HEAD` against your standards
- `/adr` — create an architecture decision record
- `/eks-setup` — bootstrap the knowledge base

**Code blocks:** every AI code block has `[Copy]` and `[Apply]`. Apply shows a full diff preview before touching anything.

---

## Inline Suggestions

`Ctrl+I` triggers a ghost text completion at the cursor (Haiku model for speed). `Tab` accepts, `Escape` dismisses.

---

## Selection Actions

Select text and a floating bar appears: **Explain**, **Fix**, **Refactor**, **→ Chat**. Each opens the AI Chat with the selection in context.

---

## LSP

| Keybinding | Action |
|-----------|--------|
| `Ctrl+Space` | Completions |
| `Ctrl+K` | Hover docs |
| `F12` | Go to definition |
| `Shift+F12` | Find all references |
| `F2` | Rename symbol |
| `Ctrl+.` | Code actions |
| `Ctrl+Shift+Space` | Signature help |

Configure servers in `user/init.lua`:

```lua
config.plugins.lsp = {
  servers = {
    zig    = { cmd = "zls" },
    rust   = { cmd = "rust-analyzer" },
    python = { cmd = "pylsp" },
  },
}
```

---

## Git

Gutter markers update every 2 seconds. Branch name shown in the status bar. `Ctrl+Shift+P` → `git:refresh-diff` to force a refresh.

---

## Terminal

`Ctrl+J` toggles the integrated terminal. Persistent shell — `cd` and env state survive between commands. Not a PTY, so interactive programs like `vim` or REPLs won't work correctly.

---

## Key Shortcuts

| | |
|---|---|
| `Ctrl+Shift+.` | AI Chat panel |
| `Ctrl+I` | Inline suggestion |
| `Ctrl+J` | Terminal |
| `Ctrl+Shift+P` | Command palette |
| `Ctrl+P` | Quick-open file |
| `F12` | Go to definition |
| `F2` | Rename symbol |
| `Ctrl+D` | Select next occurrence |
| `Ctrl+Shift+F` | Project-wide search |
| `Ctrl+Shift+;` | Record/stop macro |
| `Ctrl+;` | Play macro |
| `F11` | Fullscreen |

---

## Configuration

`user/init.lua` next to the binary:

```lua
local config = require "core.config"

config.font = renderer.font.load("data/fonts/JetBrainsMono-Regular.ttf", 14 * SCALE)
config.indent_size = 2
config.tab_type    = "soft"
config.line_limit  = 100

config.plugins.aichat = {
  model              = "sonnet",   -- "opus" | "sonnet" | "haiku"
  max_knowledge_size = 100 * 1024,
}

config.plugins.inline_suggestions = {
  model = "haiku",
}
```

---

## Plugin Development

Plugins are Lua files in `data/plugins/`. The full Lite-XL 2.1.8 API is available plus Glyph-specific APIs (`process`, `regex`, `dirmonitor`).

```lua
-- data/plugins/myplugin.lua
-- mod-version:3
local core    = require "core"
local command = require "core.command"
local keymap  = require "core.keymap"

command.add(nil, {
  ["myplugin:do-something"] = function()
    core.log("Hello from Glyph!")
  end,
})

keymap.add { ["ctrl+alt+x"] = "myplugin:do-something" }
```

To send something to the AI Chat from a plugin:

```lua
_G.glyph_ai_send("Review this:\n\n", selected_code, false)
```

---


## Repository Layout

```
src/
  main.zig          SDL3 event loop, Lua VM init
  renderer.zig      text + rect rendering
  rencache.zig      batched draw commands
  process.zig       subprocess + pipe (Win32/POSIX)
  regex.zig         PCRE2 bindings
  system.zig        files, dirs, clipboard
  dirmonitor.zig    filesystem change notifications
  api/              Lua C API layer

zig-out/share/glyph/
  core/             DocView, StatusView, RootView…
  plugins/
    aichat.lua
    lsp.lua
    gitgutter.lua
    inline_suggestions.lua
    selection_actions.lua
  colors/
  fonts/

build.zig
build.zig.zon
```

---

## Roadmap

- [ ] macOS support
- [ ] Tree-sitter incremental parsing
- [ ] EKS team sync (structured git conventions for `.glyph/`)
- [ ] Workspace profiles (switch between frontend/backend/infra context)
- [ ] Linear / Jira ticket import
- [x] Integrated terminal
- [ ] Plugin package manager

---

## License

MIT
