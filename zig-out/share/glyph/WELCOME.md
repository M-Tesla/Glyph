# Glyph — Quick Reference

Glyph is a business-driven IDE powered by a native Zig backend and Claude AI.
Built for teams that care about architecture, domain knowledge, and code quality.

Reopen the guided tour anytime: Command Palette (Ctrl+Shift+P) → "Show Tutorial"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Keyboard Shortcuts

### Navigation & Files

  Ctrl+P              Quick file open (fuzzy search)
  Ctrl+Shift+O        Open folder as project
  Ctrl+N              New file
  Ctrl+W              Close current file
  Ctrl+Tab            Switch between open files
  Ctrl+Shift+P        Command Palette (all commands)
  Ctrl+G              Go to line number
  Ctrl+Home / End     Jump to beginning / end of file


### Editing

  Ctrl+Z / Y          Undo / Redo
  Ctrl+X / C / V      Cut / Copy / Paste
  Ctrl+D              Select word (repeat to select next occurrence)
  Ctrl+L              Select current line
  Ctrl+/              Toggle line comment
  Ctrl+]  /  Ctrl+[   Indent / Unindent selection
  Alt+Up / Down       Move line(s) up / down
  Ctrl+Shift+D        Duplicate line


### Search & Replace

  Ctrl+F              Find in current file
  Ctrl+H              Find and replace in current file
  Ctrl+Shift+F        Find in all project files


### AI Features

  Ctrl+Shift+A        Open / focus AI Chat panel
  Tab                 Accept inline AI suggestion
  Escape              Dismiss inline suggestion


### Language Server (LSP)

  Ctrl+Space          Trigger completions
  Ctrl+K              Hover documentation
  F12                 Go to definition
  F2                  Rename symbol
  Ctrl+.              Code actions (fix, refactor...)
  Shift+F12           Find all references
  Ctrl+Shift+Space    Signature help


### Terminal

  Ctrl+J              Toggle integrated terminal panel
  Up / Down           Navigate command history (when terminal focused)
  Ctrl+C              Send interrupt (SIGINT)
  Ctrl+L              Clear screen


### View & Layout

  Ctrl+\              Split editor vertically
  Ctrl+Shift+\        Split editor horizontally
  Ctrl+=  /  -        Increase / decrease font scale
  F11                 Toggle fullscreen


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## AI Chat

Open with Ctrl+Shift+A. The panel docks to the right side of the editor.


### Slash Commands

Type / at the beginning of the input to see the full list:

  /explain [hint]     Explain the current selection or visible code.
                      Add a hint to focus on a specific domain aspect.

  /review [scope]     Review code using git diff.
                      Scopes: (empty) = all changes, staged, file

  /adr <title>        Create an Architecture Decision Record.
                      Saved to .glyph/decisions/ automatically.

  /eks-setup          Scaffold the .glyph/ folder structure with
                      knowledge templates and example ADRs.


### File Mentions

Type @filename anywhere in your message to inject the file's content
into the prompt. Auto-complete shows matching files in your project.

Example:  "Review the auth flow in @src/auth/login.ts"


### Tabs

  Chat          Main conversation — ask anything
  Knowledge     View and toggle .glyph/knowledge/ files
  Decisions     ADR timeline with edit and create buttons


### Export

Click the [↓md] button in the Chat header to export the full conversation
as a Markdown document (opens as a new editor tab).


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Enterprise Knowledge System (EKS)

The EKS is a structured knowledge base that lives inside your project.
It gives the AI permanent context about your business domain, architecture,
team structure, and key decisions — so you never have to explain it twice.


### Setup

Run /eks-setup in AI Chat to scaffold the .glyph/ folder:

  .glyph/
  ├── knowledge/
  │   ├── domain.md          Core entities, business rules, glossary
  │   ├── architecture.md    System overview, tech stack, services
  │   ├── standards.md       Coding standards, conventions, patterns
  │   └── team.md            Team structure and ownership
  └── decisions/
      └── YYYY-MM-DD-*.md    Architecture Decision Records


### Architecture Decision Records (ADRs)

ADRs capture *why* important technical decisions were made, not just what.
Run /adr <title> to create a new one. The AI fills in the template.

Fields: Status, Context, Decision, Consequences, Alternatives Considered


### How the AI Uses EKS

When you send a message, Glyph automatically injects relevant knowledge
files as context — prioritizing domain, architecture, standards, then ADRs.
The AI answers as if it already knows your project.


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Language Server Protocol (LSP)

Glyph supports any LSP-compatible language server.


### Connecting a Language Server

Edit your user config (Command Palette → "User Module"):

  local lsp = require "plugins.lsp"

  lsp.add_server {
    name         = "zls",
    language     = "zig",
    file_patterns = { "%.zig$" },
    command      = { "zls" },
  }

  -- More examples:
  -- clangd (C/C++):    command = { "clangd" }
  -- pyright (Python):  command = { "pyright-langserver", "--stdio" }
  -- typescript:        command = { "typescript-language-server", "--stdio" }


### Features

  Completions         Triggered by Ctrl+Space or auto on . : @
  Hover docs          Ctrl+K shows type info and documentation
  Diagnostics         Errors/warnings underlined in the editor;
                      dots in the gutter; summary in status bar
  Go to definition    F12 jumps to the symbol definition
  Rename              F2 renames across the entire project
  Code actions        Ctrl+. shows fixes and refactors at cursor
  Find references     Shift+F12 lists all usages
  Signature help      Ctrl+Shift+Space or auto on ( and ,


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Integrated Terminal

A persistent shell embedded at the bottom of the editor.

  Windows    cmd.exe
  Linux      $SHELL  (bash, zsh, fish, etc.)
  macOS      $SHELL

The shell session persists while the panel is hidden. Your working
directory, environment variables, and command history are all preserved.

Toggle with Ctrl+J. When focused, all typing goes to the shell.
Click anywhere in the editor to return focus to your code.


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Git Integration

Git change indicators appear in the line gutter automatically on save.

  Green bar     Lines added since last commit
  Yellow bar    Lines modified since last commit
  Red bar       Lines deleted (shown at deletion point)

The active branch name is displayed on the left side of the status bar.

No configuration required — works with any git repository.


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Selection Actions

Select any text in the editor. A floating toolbar appears near the selection:

  [Explain]     Ask AI to explain the selected code in plain language
  [Fix]         Ask AI to find and fix bugs in the selection
  [Refactor]    Ask AI to suggest refactoring improvements
  [→ Chat]      Send the selection to AI Chat with file context

The toolbar positions itself below the last selected line and shifts
above the selection when near the bottom of the editor.


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Inline AI Suggestions

Ghost-text completions appear as you type, powered by Claude.

  Tab        Accept the full suggestion
  Escape     Dismiss

Suggestions trigger automatically after a short idle pause.
They read your current file and surrounding context to generate
completions that match your code style and language.

Works in any file type. Most effective with code, but also works
with markdown, config files, and structured text.


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Configuration

Open your user config: Command Palette → "Open User Module"

Common settings:

  -- Font size
  style.font = renderer.font.load(
    DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", 15 * SCALE)

  -- Tab size
  config.indent_size = 2
  config.tab_type    = "soft"   -- "soft" = spaces, "hard" = tabs

  -- Ignore patterns (keep index fast)
  config.ignore_files = {
    "^%.git/", "^node_modules/", "^%.zig%-cache/", "^zig%-out/"
  }

  -- AI Chat model
  config.plugins.aichat = { model = "sonnet" }   -- or "opus"


### Themes

Open the Settings panel: Command Palette → "Settings"
Navigate to the Color Scheme section to preview and apply themes.


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Plugin Compatibility

Glyph is fully compatible with the Lite-XL plugin ecosystem.

To install a community plugin, copy the .lua file to:

  Windows    %USERDIR%\plugins\
  Linux      ~/.config/glyph/plugins/

Where %USERDIR% is the path shown in: Command Palette → "Open User Directory"

Plugins from https://github.com/lite-xl/lite-xl-plugins are compatible
as long as they target mod-version:3.


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Claude Authentication

Glyph AI features require the Claude CLI to be installed and authenticated.

Option 1 — npm (recommended, works without any IDE):
  npm install -g @anthropic-ai/claude-code
  claude login

Option 2 — VS Code, Cursor, or Windsurf extension:
  Install the Claude Code extension and sign in from there.
  Glyph detects the binary automatically.

Option 3 — Direct binary in PATH:
  Download from https://github.com/anthropics/claude-code/releases
  Place claude (or claude.exe) somewhere in your PATH.

After installing, restart Glyph. The status bar will show the AI status.


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Glyph v0.1.0
