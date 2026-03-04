# Glyph

```
   ██████╗ ██╗  ██╗   ██╗██████╗ ██╗  ██╗
  ██╔════╝ ██║  ╚██╗ ██╔╝██╔══██╗██║  ██║
  ██║  ███╗██║   ╚████╔╝ ██████╔╝███████║
  ██║   ██║██║    ╚██╔╝  ██╔═══╝ ██╔══██║
  ╚██████╔╝███████╗██║   ██║     ██║  ██║
   ╚═════╝ ╚══════╝╚═╝   ╚═╝     ╚═╝  ╚═╝
```

> The IDE that understands your business.

Most editors know your code. Glyph knows your **company**, your **domain**, your **standards**, and your **team** — and uses that context in every decision, every suggestion, every architectural record.

This is **business-driven design**: engineering grounded in business reality, not just syntax trees.

---

## Table of Contents

1. [The Problem](#the-problem)
2. [Why Glyph is Different](#why-glyph-is-different)
3. [System Requirements](#system-requirements)
4. [Installation](#installation)
5. [First Launch & Authentication](#first-launch--authentication)
6. [Enterprise Knowledge System (EKS)](#enterprise-knowledge-system-eks)
7. [Architecture Decision Records (ADR)](#architecture-decision-records-adr)
8. [AI Chat — Complete Guide](#ai-chat--complete-guide)
   - [Opening the Panel](#opening-the-panel)
   - [Tabs Overview](#tabs-overview)
   - [Sending Messages & File Mentions](#sending-messages--file-mentions)
   - [Slash Commands](#slash-commands)
   - [Multi-Agent System](#multi-agent-system)
   - [Code Blocks — Copy, Apply & Diff Preview](#code-blocks--copy-apply--diff-preview)
   - [Input History](#input-history)
   - [Chat Export](#chat-export)
9. [Inline AI Suggestions](#inline-ai-suggestions)
10. [Selection Actions](#selection-actions)
11. [IDE Features (LSP)](#ide-features-lsp)
    - [Code Completions](#code-completions)
    - [Hover Documentation](#hover-documentation)
    - [Go to Definition](#go-to-definition)
    - [Find All References](#find-all-references)
    - [Rename Symbol](#rename-symbol)
    - [Code Actions & Quick Fixes](#code-actions--quick-fixes)
    - [Signature Help](#signature-help)
    - [Diagnostics](#diagnostics)
12. [Git Integration](#git-integration)
13. [Core Editor Features](#core-editor-features)
    - [Find & Replace](#find--replace)
    - [Multiple Cursors & Selection](#multiple-cursors--selection)
    - [Code Transformation](#code-transformation)
    - [Macro Recording & Playback](#macro-recording--playback)
    - [Project-Wide Search](#project-wide-search)
    - [File Tree Sidebar](#file-tree-sidebar)
    - [Themes & Zoom](#themes--zoom)
14. [Complete Keyboard Shortcuts Reference](#complete-keyboard-shortcuts-reference)
15. [Configuration Reference](#configuration-reference)
16. [Supported Languages](#supported-languages)
17. [Building from Source](#building-from-source)
18. [Plugin Development](#plugin-development)
19. [Architecture](#architecture)
20. [Roadmap](#roadmap)
21. [Acknowledgements](#acknowledgements)

---

## The Problem

You open your editor. You start a new feature. You ask the AI for help.

It has no idea:
- What your company actually does
- What bounded contexts exist in your domain
- What your team's engineering standards are
- What architectural decisions were already made and why

So you explain. Again. Every session. Every developer. Every time.

**Glyph solves this at the IDE level.**

---

## Why Glyph is Different

| Capability | Glyph | Typical AI editor |
|-----------|-------|-------------------|
| Understands your business domain | ✅ EKS knowledge base | ❌ |
| Tracks architectural decisions over time | ✅ ADR system | ❌ |
| Separates business context from code context | ✅ Layered knowledge | ❌ |
| Multi-agent conversations | ✅ | Rarely |
| Applies AI-suggested diffs with visual preview | ✅ | Rarely |
| Native binary — no Electron, no browser | ✅ | ❌ (most) |
| Full LSP: rename, references, signatures, actions | ✅ | Sometimes |
| Git diff markers in gutter + branch in status bar | ✅ | Sometimes |
| Ghost text inline completions | ✅ | Sometimes |
| Windows and Linux | ✅ | Varies |
| Integrated terminal (cmd/bash) | ✅ `Ctrl+J` | Sometimes |

---

## System Requirements

### Windows
- Windows 10 64-bit or later
- **Claude Code CLI** — via `npm install -g @anthropic-ai/claude-code`, or bundled in VS Code / Cursor / Windsurf extension
- Git in PATH (optional — for git gutter)
- Language server binary (optional — for LSP features, e.g. `zls` for Zig)

### Linux
- x86-64, Ubuntu 20.04+ / Fedora 36+ / Arch or equivalent
- SDL3 shared library (`libSDL3.so`)
- FreeType (`libfreetype.so`)
- **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`, or bundled in any supported IDE extension
- Git (optional)
- Language server binary (optional)

### Hardware
- Any modern x86-64 CPU
- ~50 MB disk space
- ~128 MB RAM typical usage; ~30 ms cold startup

---

## Installation

### Windows

1. Download `glyph-windows-x64.zip` from the [Releases](../../releases) page.
2. Extract to any folder, e.g. `C:\Glyph\`.
3. Double-click `glyph.exe`.

No installer, no admin rights, no registry keys. User data is stored in `user/` next to the executable.

### Linux

1. Download `glyph-linux-x64.tar.gz` from the [Releases](../../releases) page.
2. Extract and run:
   ```bash
   tar -xzf glyph-linux-x64.tar.gz
   cd glyph
   chmod +x glyph
   ./glyph
   ```
3. Optionally move to `/usr/local/bin/` for system-wide access.

### Opening a Project

| Method | How |
|--------|-----|
| From the launcher | Drag a folder onto the window |
| From the menu | `File → Open Folder` or `Ctrl+Shift+O` |
| From the terminal | `glyph /path/to/project` |

The editor remembers the last-opened project and restores it on next launch.

---

## First Launch & Authentication

Glyph uses the **Claude Code CLI** for all AI features. No API key is needed — authentication is handled by the CLI itself.

**VS Code is not required.** There are three ways to provide the CLI, in order of priority that Glyph searches:

---

### Option A — Standalone install (recommended, no IDE needed)

Install the Claude Code CLI directly via npm:

```bash
# Requires Node.js 18+
npm install -g @anthropic-ai/claude-code
```

Then log in once:

```bash
claude auth login
```

That's it. Glyph finds the binary automatically via `which claude` / `where claude.exe`.

> **No VS Code. No extension. Just the CLI.**

---

### Option B — VS Code / Cursor / VS Code Insiders / Windsurf extension

If you already use one of these editors with the **Claude Code** extension installed and signed in, Glyph finds the bundled binary automatically — nothing to configure.

Glyph searches these locations in order:

| IDE | Extension directory |
|-----|-------------------|
| VS Code | `~/.vscode/extensions/` |
| Cursor | `~/.cursor/extensions/` |
| VS Code Insiders | `~/.vscode-insiders/extensions/` |
| Windsurf | `~/.windsurf/extensions/` |

---

### Option C — Binary in PATH

If you have `claude` (Linux/macOS) or `claude.exe` (Windows) anywhere in your system PATH, Glyph will find it automatically regardless of where it came from.

---

### Verifying Authentication in Glyph

Open the AI Chat panel (`Ctrl+Shift+.`) and look at the panel header:

| Header text | Meaning |
|-------------|---------|
| `● Logged in as you@email.com` | Ready — all AI features work |
| `○ Not logged in — Click to login` | Click to open a login terminal |
| `○ claude not found` | None of the above options found; see installation above |

Click the status text to trigger the login flow. A terminal window opens for browser-based authentication. After completing it, click **Refresh** in the AI Chat panel.

> **Subscription required:** Claude Pro or Team plan. The CLI uses OAuth — your credentials are stored securely by the CLI itself, never by Glyph.

---

## Enterprise Knowledge System (EKS)

EKS is the core of Glyph. It's a structured, versioned knowledge base that lives in your project and travels with your code.

```
your-project/
└── .glyph/
    ├── company.md    ← What your company does, who it serves, business model
    ├── domain.md     ← System architecture, bounded contexts, data flows
    ├── standards.md  ← Engineering standards, review process, tooling decisions
    ├── team.md       ← Team structure, roles, decision-making norms
    └── adr/
        ├── 2025-01-15-use-postgresql.md
        ├── 2025-02-03-adopt-event-sourcing.md
        └── 2025-03-10-deprecate-rest-for-grpc.md
```

This context is **automatically injected** into every AI interaction — not as a one-time system prompt, but as a living, git-versioned part of your repository that the whole team maintains.

### Injection Hierarchy

```
~/.glyph/          ← global (your identity as a developer, applies to all projects)
project/.glyph/    ← project-specific (overrides / extends global)
    ├── company.md
    ├── domain.md
    ├── standards.md
    ├── team.md
    └── adr/
```

Global layers apply across all projects. Project layers add specificity. New team member? Clone the repo, open Glyph — full context, day one.

### Setting Up EKS with /eks-setup

Bootstrap your knowledge base in seconds. In the AI Chat input, type:

```
/eks-setup
```

The AI will ask you questions about your company, tech stack, team, and infrastructure. It then generates all four files (company, domain, standards, team) and saves them to `.glyph/` immediately. Commit them to git so the whole team benefits.

### Managing EKS Files

In the **Knowledge** tab of the AI Chat panel:

- Each `.glyph/` file appears with a **checkbox** — check to include it in context, uncheck to exclude
- **[Edit]** next to each file — opens the file in the main editor
- **[+ New .md]** — creates a new timestamped `.md` in `.glyph/` for additional context layers
- **[Refresh all]** — rescans the knowledge directory (useful after editing files externally)
- Files auto-reload when modified externally — Glyph polls every 4 seconds

### Global Knowledge

Files in `<user data>/knowledge/` apply to *all* your projects. Use this for:
- Your personal engineering profile
- Company-wide standards shared across repos
- Team conventions you always want the AI to know

---

## Architecture Decision Records (ADR)

ADRs are structured documents that capture *why* a technical decision was made. In Glyph, they are first-class artifacts — not documentation afterthoughts.

Every enabled ADR is automatically injected into each AI conversation. This means the AI will know:
- What decisions were already made and why
- What alternatives were rejected
- What tradeoffs were accepted

### Creating an ADR

**Option 1 — via slash command:**
```
/adr
```
The AI drafts the ADR in context of your existing architecture (`domain.md`), your standards, and previous decisions. It saves the file to `.glyph/adr/YYYY-MM-DD-title.md`.

**Option 2 — manually:**
1. Open the **Decisions** tab in the AI Chat panel
2. Click **[+ New .md]**
3. Edit the file that opens in the main editor

### Viewing ADRs

The **Decisions** tab shows a timeline of all ADRs in `.glyph/adr/`, sorted by date. Each entry shows the date, title, and a short excerpt. Click **[Edit]** to open any ADR in the editor.

### ADR Format

```markdown
# ADR: Use PostgreSQL over MongoDB

**Status:** Accepted
**Date:** 2025-01-15

## Context
Our order processing domain requires ACID transactions across multiple tables.
MongoDB's multi-document transactions have significant performance overhead.

## Decision
Use PostgreSQL 15 as the primary database for all transactional data.

## Consequences
- Enforced schema — all migrations go through Flyway
- Read replicas for analytics workloads
- Full-text search via pg_trgm (no Elasticsearch dependency)
```

---

## AI Chat — Complete Guide

### Opening the Panel

| Action | How |
|--------|-----|
| Toggle panel | `Ctrl+Shift+.` |
| Focus input when panel is open | `Ctrl+.` |
| New conversation | `Ctrl+Shift+N` |

---

### Tabs Overview

#### Chat
The main conversation interface. Messages stream in real time. Code blocks have [Copy] and [Apply] buttons.

#### Agents
Create and switch between multiple independent AI agents — each with its own history and session. See [Multi-Agent System](#multi-agent-system).

#### Knowledge
Manage which EKS/knowledge files are included in context. Toggle files on/off, create new ones, refresh the list.

#### Context
Shows exactly what gets prepended to every message you send:

```
[Company]      ← company.md content
[Domain]       ← domain.md content
[Standards]    ← standards.md content
[ADRs]         ← all records in .glyph/adr/
[Knowledge]    ← enabled files from knowledge/
──────────────
Your message
```

Use this tab to debug why the AI gave an unexpected answer — you can see exactly what it knew.

#### Decisions
ADR timeline viewer. Browse all architecture decisions in chronological order.

---

### Sending Messages & File Mentions

| Action | How |
|--------|-----|
| Send message | **Enter** |
| Insert newline in input | **Shift+Enter** |
| Browse input history | **↑ / ↓** arrow keys |
| Mention a file | Type **@** then start typing the filename |
| Run a slash command | Type **/** at the very start of the input |
| Stop AI response | Click **[Stop]** button (visible during generation) |

#### @mention files

Type `@` anywhere in the input to trigger a file autocomplete popup. Select a file and its **full content** is injected into the message. Example uses:

```
Review @src/auth/login.ts for timing attack vulnerabilities

Refactor @components/OrderTable.tsx — extract the row rendering to a hook

Why is @migrations/V42__add_index.sql using a non-concurrent index?
```

The file content is included inline — the AI sees the actual code, not just the path.

---

### Slash Commands

Type `/` at the start of the input to see the command autocomplete menu. Press **Tab** or click to complete.

| Command | What it does |
|---------|-------------|
| `/explain` | Takes the currently selected text (or active file) and asks the AI to explain it in plain business terms. Auto-sends immediately. Great for understanding unfamiliar code before a review. |
| `/review` | Runs `git diff HEAD` and sends the diff for review. The AI evaluates it against your `standards.md` and existing ADRs — not generic advice. |
| `/adr` | Starts an interactive ADR creation flow. The AI asks for title, context, decision, and consequences, then saves the record to `.glyph/adr/`. |
| `/eks-setup` | Bootstraps the full EKS knowledge base for the current project by interviewing you about your company, domain, standards, and team. |

---

### Multi-Agent System

Each **agent** in Glyph is an independent conversation with its own:
- Message history
- Claude session ID (conversations survive editor restarts)
- Context window

**Creating agents:**
1. Go to the **Agents** tab
2. Click **[+ New Agent]**
3. Give it a name

**Switching agents:** Click the agent name in the Agents tab. The Chat tab immediately shows that agent's history.

**Suggested agent layout for a team:**

| Agent name | Focus |
|-----------|-------|
| Backend | API design, database, business logic |
| Frontend | UI components, state management, design system |
| Review | Strict code review against standards.md |
| Infra | EKS, deployments, CI/CD, Terraform |

Each agent uses the same EKS context but maintains completely separate conversations.

---

### Code Blocks — Copy, Apply & Diff Preview

When the AI responds with code, each code block has two action buttons:

**[Copy]** — copies the raw code to clipboard.

**[Apply]** — opens a full-screen **diff preview modal** before making any changes. The modal shows:

| Color | Meaning |
|-------|---------|
| Green highlight | Lines that will be added |
| Red highlight | Lines that will be removed |
| Gray / uncolored | Context (3 lines around each change) |

Controls in the diff modal:

| Action | How |
|--------|-----|
| Confirm and apply | Click **[Confirm]** or **Enter** |
| Cancel | Click **[Cancel]** or **Escape** |
| Scroll large diffs | Mouse wheel or trackpad |

The diff algorithm uses LCS (Longest Common Subsequence) for accurate change detection — it won't accidentally match unrelated lines.

---

### Input History

The last 200 messages you've typed are persisted across sessions. Use **↑ / ↓** in the input field to navigate. If you've started typing a new draft, pressing **↓** past the end of history restores it.

---

### Chat Export

Click the **[↓md]** button in the chat header to export the entire conversation as a Markdown document. It opens as a new file in the editor — save it, commit it, or paste it into a wiki.

---

## Inline AI Suggestions

Ghost text completions powered by Claude — similar to GitHub Copilot.

| Keybinding | Action |
|-----------|--------|
| `Ctrl+I` | Trigger a suggestion at the cursor |
| `Tab` | Accept the suggestion (inserts ghost text) |
| `Escape` | Dismiss the suggestion |

When triggered, Glyph sends the 40 lines before and 10 lines after the cursor to Claude (Haiku model for speed) and renders the suggestion as **dim ghost text** on the same line. Any other keystroke cancels it cleanly.

The process runs in a background coroutine — the editor stays fully responsive while Claude generates the suggestion.

---

## Selection Actions

Select any text in the editor. A **floating action bar** appears near the selection automatically:

| Button | Prompt sent to AI | Auto-sends? |
|--------|-------------------|------------|
| **[Explain]** | "Explain the following code in plain terms:" | ✅ Yes |
| **[Fix]** | "Fix any bugs in the following code:" | No — opens chat for you to add context |
| **[Refactor]** | "Refactor the following code for clarity:" | No |
| **[→ Chat]** | Opens chat with selection as context, no preset prompt | No |

The bar appears **below** the selection, right-aligned. If the selection is near the bottom of the window, the bar moves **above** instead. Clicking any button opens or focuses the AI Chat panel.

---

## IDE Features (LSP)

Glyph includes a complete **Language Server Protocol** client. Any language that has an LSP server gains full IDE intelligence.

### Supported Language Servers (built-in configuration)

| Language | Server binary | Install |
|----------|--------------|---------|
| Zig | `zls` | [github.com/zigtools/zls](https://github.com/zigtools/zls) |
| Lua | `lua-language-server` | [github.com/LuaLS/lua-language-server](https://github.com/LuaLS/lua-language-server) |

Other servers (Rust, Python, TypeScript, Go, etc.) can be added in configuration. The binary just needs to be in your PATH.

---

### Code Completions

**Keybinding:** `Ctrl+Space`

A popup appears with up to 10 suggestions from the language server. The list also appears automatically when you type `.`, `:`, or `@`.

| Action | Key |
|--------|-----|
| Navigate list | `↑` / `↓` |
| Insert selected item | `Enter` |
| Dismiss | `Escape` |

---

### Hover Documentation

**Keybinding:** `Ctrl+K`

Displays a popup near the cursor with:
- The type of the symbol
- Its full signature (for functions)
- Documentation comment

Press `Ctrl+K` again (or `Escape`) to dismiss.

---

### Go to Definition

**Keybinding:** `F12` or `Ctrl+F12`

Jumps to where the symbol under the cursor is defined. If the definition is in a different file, that file opens automatically at the correct line and column.

---

### Find All References

**Keybinding:** `Shift+F12`

Finds every place in the codebase where the symbol under the cursor is used. Results appear in a **searchable list** — type to filter. Select any result to jump to it.

If there is only one reference, Glyph jumps directly without showing the list.

---

### Rename Symbol

**Keybinding:** `F2`

Renames the symbol under the cursor **across the entire project**. A text prompt appears — type the new name and press `Enter`. All occurrences in all files are updated atomically, in the correct order (reverse to avoid offset shifts).

---

### Code Actions & Quick Fixes

**Keybinding:** `Ctrl+.`

Shows available actions at the current cursor position:
- **Quick fixes** — "Add missing import", "Add type annotation", etc.
- **Refactoring** — "Extract to function", "Inline variable", etc.
- **Language-specific** — server-defined actions

| Action | Key |
|--------|-----|
| Navigate items | `↑` / `↓` |
| Execute selected | `Enter` |
| Dismiss | `Escape` |

---

### Signature Help

**Keybinding:** `Ctrl+Shift+Space`

Shows the signature of the function being called, with the **current parameter highlighted** in accent color. Auto-triggers on `(` and `,`. Auto-hides on `)`.

Useful when calling functions with many parameters — you always know which argument you're filling in.

---

### Diagnostics

Errors and warnings from the language server appear in three places:

**Gutter** — A colored dot in the line number area marks lines with issues.

**Status bar** (bottom-right corner):

| Display | Meaning |
|---------|---------|
| `ZLS ok` (green) | No errors or warnings |
| `ZLS 3E 1W` (red) | 3 errors, 1 warning |
| `ZLS ...` (dimmed) | Server is initializing |
| `[ZLS off]` (red) | Server not found |

---

## Integrated Terminal

**Keybinding:** `Ctrl+J`

Glyph includes a built-in terminal panel that slides up from the bottom of the window — similar to VS Code's integrated terminal.

### Opening and Closing

| Action | How |
|--------|-----|
| Toggle panel open/close | `Ctrl+J` |
| Focus the input (when panel is open) | Click anywhere in the panel |
| Unfocus (keep panel open) | `Escape` |
| Close panel | Click `×` in the header, or `Ctrl+J` again |

### Shell

Glyph automatically uses the right shell for each platform:

| Platform | Shell used |
|----------|-----------|
| **Windows** | `cmd.exe /Q` (batch mode, command echoing suppressed) |
| **Linux / macOS** | `$SHELL -s` (your login shell, e.g. bash, zsh, fish) |

When the panel opens, the shell automatically `cd`s to the current project root.

### Typing Commands

Click inside the panel to focus. Type your command and press **Enter** to run it.

| Action | Key |
|--------|-----|
| Run command | `Enter` |
| Navigate command history | `↑` / `↓` |
| Move cursor left / right | `←` / `→` |
| Jump to start of input | `Home` |
| Jump to end of input | `End` |
| Delete char left | `Backspace` |
| Delete char right | `Delete` |
| Send interrupt (Ctrl+C) | `Ctrl+C` |
| Clear output | `Ctrl+Shift+K` |

### Persistent Shell

The shell process stays alive between commands — so `cd`, environment variables, and shell state all persist across commands in the same session. Close and reopen the panel to restart the shell.

### Output Colors

| Color | Meaning |
|-------|---------|
| White | Standard command output |
| Accent color (blue/purple) | Commands you typed (`$ command`) |
| Dimmed | System messages (`[Terminal ready]`, `[Shell exited]`) |

### Limitations

The terminal uses **pipes** (not a PTY/pseudo-terminal), which means:
- Interactive programs like `vim`, `python` REPL, or `top` will not display correctly
- Programs that require TTY features (color output, progress bars) may behave differently
- `git commit` without `-m` will open the editor in the shell, not in Glyph

For interactive sessions, use your system terminal. For build commands, scripts, git operations, and CLI tools — the integrated terminal works great.

---

## Git Integration

Glyph shows live git diff information in the editor without any configuration. Requires `git` in PATH.

### Gutter Markers

As you edit files, colored bars appear in the gutter (left of line numbers):

| Color | Meaning |
|-------|---------|
| **Green** | Lines added since last commit |
| **Yellow / Orange** | Lines modified since last commit |
| **Red** (stub marker) | Lines deleted at this position |

The gutter refreshes every 2 seconds and immediately when you switch to another file.

### Branch Name

The current branch is shown in the **bottom-left of the status bar** with a branch icon (⎇). Nothing is shown for non-git directories.

### Force Refresh

Open the command palette (`Ctrl+Shift+P`) and run `git:refresh-diff` to force an immediate re-scan.

---

## Core Editor Features

### Find & Replace

| Keybinding | Action |
|-----------|--------|
| `Ctrl+F` | Open Find bar |
| `Ctrl+H` | Open Find & Replace bar |
| `F3` | Find next match |
| `Shift+F3` | Find previous match |
| `Ctrl+D` | Select next occurrence of current selection |
| `Ctrl+Shift+F` | Search across all project files |

**In the Find bar:**
- Toggle **regex mode** to use regular expressions in the search pattern
- Toggle **case sensitivity** for exact-case matching

### Multiple Cursors & Selection

| Keybinding | Action |
|-----------|--------|
| `Ctrl+Click` | Add a cursor at click position |
| `Ctrl+D` | Add next occurrence of selection to multi-selection |
| `Ctrl+L` | Select current line |
| `Ctrl+A` | Select all |
| `Escape` | Return to single cursor |

With multiple cursors active, every edit, navigation, and transformation applies to all cursors simultaneously. Great for renaming variables, adding commas to a list, or wrapping multiple lines.

### Code Transformation

| Keybinding | Action |
|-----------|--------|
| `Ctrl+]` | Indent selection one level |
| `Ctrl+[` | Unindent selection one level |
| `Ctrl+/` | Toggle line comment (`//` style) |
| `Ctrl+Shift+/` | Toggle block comment (`/* */` style) |
| `Ctrl+Shift+D` | Duplicate current line(s) |
| `Ctrl+Shift+K` | Delete current line(s) |
| `Ctrl+Shift+↑` | Move line(s) up |
| `Ctrl+Shift+↓` | Move line(s) down |

### Macro Recording & Playback

Record any sequence of keystrokes and replay it — useful for mechanical repetitive edits.

| Keybinding | Action |
|-----------|--------|
| `Ctrl+Shift+;` | **Start** recording (status bar shows "Recording macro…") |
| `Ctrl+Shift+;` | **Stop** recording |
| `Ctrl+;` | **Play** the last recorded macro |

**Example use case:** adding a trailing comma to 20 struct fields — record the steps on one field, play back on each of the others.

### Project-Wide Search

Run **`project-search:find`** from the command palette (`Ctrl+Shift+P`), or use `Ctrl+Shift+F`.

A dedicated results panel opens. Type a search term — Glyph searches every file in the project directory and shows matches with file path and surrounding context. Click any result to jump to it.

### File Tree Sidebar

| Keybinding / Action | Result |
|--------------------|--------|
| `Ctrl+\` | Toggle file tree visibility |
| Click folder arrow | Expand / collapse folder |
| Click file | Open file |
| Right-click file | Context menu: New file, New folder, Rename, Delete, Search in directory |

### Themes & Zoom

**Switch theme:** Open the command palette (`Ctrl+Shift+P`) and run `ui:select-theme`. Over 60 themes are included — Monokai, Dracula, Nord, Gruvbox, Catppuccin, Tokyo Night, One Dark, Solarized, and more.

**Zoom:** The editor supports UI scaling.

| Keybinding | Action |
|-----------|--------|
| `Ctrl+Shift+=` | Increase font/UI size |
| `Ctrl+Shift+-` | Decrease font/UI size |
| `Ctrl+Shift+0` | Reset to default size |

---

## Complete Keyboard Shortcuts Reference

### Application & Files

| Keybinding | Action |
|-----------|--------|
| `Ctrl+N` | New document |
| `Ctrl+O` | Open file |
| `Ctrl+Shift+O` | Open folder / project |
| `Ctrl+S` | Save |
| `Ctrl+Shift+S` | Save as |
| `Ctrl+W` | Close current tab |
| `Ctrl+Q` | Quit |
| `F11` | Toggle fullscreen |
| `Ctrl+Shift+P` | Command palette |
| `Ctrl+P` | Quick-open file (fuzzy search) |

### Navigation

| Keybinding | Action |
|-----------|--------|
| `Ctrl+Home` | Jump to start of document |
| `Ctrl+End` | Jump to end of document |
| `Ctrl+G` | Go to line number |
| `Ctrl+Tab` | Next open tab |
| `Ctrl+Shift+Tab` | Previous open tab |
| `Ctrl+F` | Find in current file |
| `Ctrl+H` | Find and replace |
| `F3` | Find next |
| `Shift+F3` | Find previous |
| `Ctrl+Shift+F` | Search in all project files |

### Editing

| Keybinding | Action |
|-----------|--------|
| `Ctrl+Z` | Undo |
| `Ctrl+Y` | Redo |
| `Ctrl+X` | Cut |
| `Ctrl+C` | Copy |
| `Ctrl+V` | Paste |
| `Ctrl+A` | Select all |
| `Ctrl+L` | Select current line |
| `Ctrl+D` | Select next occurrence |
| `Tab` | Indent selection |
| `Shift+Tab` | Unindent selection |
| `Ctrl+/` | Toggle line comment |
| `Ctrl+Shift+/` | Toggle block comment |
| `Ctrl+Shift+D` | Duplicate line(s) |
| `Ctrl+Shift+K` | Delete line(s) |
| `Ctrl+Shift+↑` | Move line(s) up |
| `Ctrl+Shift+↓` | Move line(s) down |
| `Ctrl+'` | Wrap selection in quotes |

### AI Features

| Keybinding | Action |
|-----------|--------|
| `Ctrl+Shift+.` | Toggle AI Chat panel |
| `Ctrl+.` | Focus AI Chat input |
| `Ctrl+Shift+N` | New AI conversation |
| `Ctrl+I` | Trigger inline AI suggestion |
| `Tab` | Accept inline suggestion |
| `Escape` | Dismiss suggestion / popup |

### LSP / IDE Intelligence

| Keybinding | Action |
|-----------|--------|
| `Ctrl+Space` | Code completions popup |
| `Ctrl+K` | Hover documentation |
| `F12` | Go to definition |
| `Ctrl+F12` | Go to definition (alt) |
| `Shift+F12` | Find all references |
| `F2` | Rename symbol |
| `Ctrl+.` | Code actions / quick fix |
| `Ctrl+Shift+Space` | Signature help |

### Terminal

| Keybinding | Action |
|-----------|--------|
| `Ctrl+J` | Toggle integrated terminal |
| `Enter` | Run command (when terminal focused) |
| `↑` / `↓` | Navigate command history |
| `Ctrl+C` | Interrupt running process |
| `Ctrl+Shift+K` | Clear terminal output |
| `Escape` | Unfocus terminal (keep panel open) |

### Macros & Other

| Keybinding | Action |
|-----------|--------|
| `Ctrl+Shift+;` | Start / stop macro recording |
| `Ctrl+;` | Play recorded macro |
| `Ctrl+\` | Toggle file tree |
| `Ctrl+Shift+=` | Increase zoom |
| `Ctrl+Shift+-` | Decrease zoom |
| `Ctrl+Shift+0` | Reset zoom |

---

## Configuration Reference

User settings are written in Lua. Create or edit `user/init.lua` in the same folder as the executable (or in the user data directory).

```lua
local config = require "core.config"

---------------------------------------------------------------------------
-- Editor appearance
---------------------------------------------------------------------------
config.font = renderer.font.load("data/fonts/JetBrainsMono-Regular.ttf", 14 * SCALE)
config.code_font = config.font  -- code and UI use the same font by default

---------------------------------------------------------------------------
-- Editing behaviour
---------------------------------------------------------------------------
config.indent_size       = 2        -- spaces per indent level
config.tab_type          = "soft"   -- "soft" (spaces) or "hard" (tabs)
config.line_limit        = 100      -- visual guide line at column 100
config.max_undos         = 500      -- undo history depth
config.highlight_current_line = true
config.line_endings      = "crlf"   -- "crlf" (Windows) or "lf" (Linux/macOS)

---------------------------------------------------------------------------
-- AI Chat
---------------------------------------------------------------------------
config.plugins.aichat = {
  model               = "sonnet",       -- "opus" | "sonnet" | "haiku"
  max_knowledge_size  = 100 * 1024,     -- max bytes of knowledge injected (100 KB)
  size                = 340 * SCALE,    -- panel width in pixels
}

---------------------------------------------------------------------------
-- Inline suggestions
---------------------------------------------------------------------------
config.plugins.inline_suggestions = {
  model                = "haiku",  -- haiku is fastest; sonnet for better quality
  context_lines_before = 40,
  context_lines_after  = 10,
}

---------------------------------------------------------------------------
-- LSP — add as many servers as you need
---------------------------------------------------------------------------
config.plugins.lsp = {
  servers = {
    zig    = { cmd = "zls",                  name = "ZLS"   },
    lua    = { cmd = "lua-language-server",  name = "LuaLS" },
    rust   = { cmd = "rust-analyzer",        name = "RA"    },
    python = { cmd = "pylsp",                name = "PyLSP" },
    ts     = { cmd = "typescript-language-server", args = {"--stdio"}, name = "TSLS" },
    go     = { cmd = "gopls",               name = "gopls" },
  },
  max_completions = 10,
  trigger_chars   = { ".", ":", "@" },
}

---------------------------------------------------------------------------
-- Git gutter colours
---------------------------------------------------------------------------
config.plugins.gitgutter = {
  scan_interval   = 2000,                   -- ms between automatic rescans
  branch_interval = 15,                     -- seconds between branch re-checks
  color_added     = {  80, 200, 100, 255 }, -- green
  color_modified  = { 230, 180,  50, 255 }, -- amber
  color_deleted   = { 220,  60,  60, 255 }, -- red
}

---------------------------------------------------------------------------
-- Autocomplete (local symbol cache)
---------------------------------------------------------------------------
config.plugins.autocomplete = {
  min_len        = 3,    -- characters before suggestions appear
  max_height     = 6,    -- visible items in popup
  max_suggestions = 100,
}
```

---

## Supported Languages

Syntax highlighting is included for 100+ languages. LSP intelligence requires the corresponding server installed separately.

| Category | Languages |
|----------|-----------|
| **Systems** | Zig, C, C++, Rust, Go, D, Nim, Odin, V, Crystal |
| **JVM / CLR** | Java, Kotlin, Scala, C#, F# |
| **Scripting** | Python, Ruby, Lua, Perl, PHP, Julia, R, Tcl |
| **Web** | JavaScript, TypeScript, JSX, TSX, HTML, CSS, SCSS, SASS, Vue, Svelte |
| **Mobile** | Swift, Kotlin, Dart |
| **Functional** | Haskell, OCaml, Elixir, Erlang, Clojure, Racket, Common Lisp, F# |
| **Shell** | Bash, Zsh, PowerShell, Batch, Fish |
| **Data / Config** | YAML, TOML, JSON, JSONC, XML, HCL, INI, TOML, Nix, Dhall |
| **Infrastructure** | Dockerfile, Terraform (HCL), Nginx, Apache config, systemd unit |
| **Query** | SQL, GraphQL, SPARQL, Cypher |
| **Markup / Docs** | Markdown, reStructuredText, LaTeX, AsciiDoc, Org-mode |
| **Assembly** | x86, x86-64, RISC-V, ARM, MIPS |
| **Legacy** | COBOL, Fortran, Ada, Pascal, BASIC |
| **Misc** | Zig, Odin, WebAssembly (WAT), Verilog, VHDL, GLSL, HLSL |

---

## Building from Source

### Requirements

| Tool | Version |
|------|---------|
| [Zig](https://ziglang.org/download/) | 0.15.2 |
| Git | any |

All other dependencies (SDL3, FreeType, Lua 5.4, PCRE2) are fetched and compiled automatically on the first build.

### Clone and Build

```bash
git clone https://github.com/your-org/glyph.git
cd glyph

zig build                  # debug build (default)
zig build -Doptimize=ReleaseSafe   # optimized + safety checks
zig build -Doptimize=ReleaseFast   # maximum performance, no safety
```

Outputs:
- **Binary:** `zig-out/bin/glyph` (Linux) / `zig-out/bin/glyph.exe` (Windows)
- **Runtime data:** `zig-out/bin/data/` (Lua core, plugins, fonts, themes)

### Run

```bash
# Linux
./zig-out/bin/glyph

# Windows
zig-out\bin\glyph.exe

# Open a specific project
./zig-out/bin/glyph /path/to/project
```

### Repository Layout

```
glyph/
├── src/                         # Zig backend
│   ├── main.zig                 # Entry point, SDL3 event loop
│   ├── renderer.zig             # SDL3 + FreeType text rendering
│   ├── rencache.zig             # Batched draw command cache
│   ├── process.zig              # Subprocess + pipe management (Win32/POSIX)
│   ├── regex.zig                # PCRE2 bindings
│   ├── system.zig               # Platform abstraction: files, dirs, clipboard
│   ├── dirmonitor.zig           # Filesystem change notification
│   └── api/                     # Lua C API layer
├── zig-out/
│   └── share/glyph/             # Lua frontend (the "source" for runtime data)
│       ├── core/                # Editor core: DocView, StatusView, RootView…
│       ├── plugins/             # All plugins
│       │   ├── aichat.lua       # AI Chat + EKS + ADR + multi-agent
│       │   ├── lsp.lua          # Language Server Protocol client
│       │   ├── gitgutter.lua    # Git diff markers + branch status
│       │   ├── inline_suggestions.lua  # Ghost text completions
│       │   ├── selection_actions.lua   # Floating Explain/Fix/Refactor buttons
│       │   └── …               # 150+ language syntax files + utilities
│       ├── colors/              # Color themes
│       └── fonts/               # Bundled JetBrains Mono and others
├── build.zig                    # Build system
├── build.zig.zon                # Package dependencies
└── README.md
```

---

## Plugin Development

Plugins are Lua files placed in `data/plugins/`. The full **Lite-XL 2.1.8 API** is available, plus Glyph-specific APIs (`process`, `regex`, `dirmonitor`).

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

### Integrate with AI Chat

Any plugin can open the AI Chat with pre-filled content using the global hook:

```lua
-- Send a message to AI Chat, optionally auto-sending it
_G.glyph_ai_send(
  "Review this function for edge cases:\n\n",  -- prefix
  selected_code,                                -- code block
  false                                         -- auto_send: true = send immediately
)
```

See [`zig-out/share/glyph/plugins/selection_actions.lua`](zig-out/share/glyph/plugins/selection_actions.lua) for a real example.

---

## Architecture

Glyph is a thin Zig backend bound to a Lua frontend. The Zig layer handles everything that must be fast or needs OS access. The Lua layer handles everything that benefits from being flexible and hot-reloadable.

```
┌─────────────────────────────────────────────────────────┐
│                     Lua Frontend                         │
│   core/          plugins/                                │
│   ├─ docview     ├─ aichat.lua       ← EKS + AI Chat    │
│   ├─ rootview    ├─ lsp.lua          ← LSP client        │
│   ├─ statusview  ├─ gitgutter.lua    ← Git integration   │
│   └─ …           ├─ inline_suggestions.lua               │
│                  ├─ selection_actions.lua                 │
│                  └─ projectsearch.lua + 150 more          │
├──────────────────────┬──────────────────────────────────┤
│                 Zig Backend                               │
│   renderer.zig    rencache.zig    renwindow.zig           │
│   api/system      api/process    api/regex                │
│   api/dirmonitor  api/utf8extra                           │
├──────────────────────┴──────────────────────────────────┤
│      SDL3       FreeType       Lua 5.4       PCRE2        │
└─────────────────────────────────────────────────────────┘
                           │
               claude (Claude Code CLI)
               ZLS / lua-language-server / …
```

**AI authentication:** Glyph uses the Claude Code CLI bundled with the VS Code extension. If you're logged in to Claude Code, Glyph uses those credentials — no separate API key needed.

---

## Roadmap

- [ ] macOS support
- [ ] Tree-sitter incremental syntax highlighting
- [ ] EKS team sync workflow (structured git conventions for `.glyph/`)
- [ ] Workspace profiles — switch between frontend / backend / infra context sets
- [ ] Ticket integration — import Linear / Jira ticket → AI plans implementation in EKS context
- [x] Integrated terminal (`Ctrl+J`) — cmd.exe / $SHELL with persistent state
- [ ] Multi-root workspace UI
- [ ] Package manager for plugins (install Lite-XL compatible plugins)

---

## Acknowledgements

- [Lite-XL](https://github.com/lite-xl/lite-xl) — Lua frontend this project builds on (MIT)
- [Zig](https://ziglang.org/) — systems language for the backend
- [Anthropic](https://anthropic.com) — Claude AI and Claude Code CLI
- [SDL3](https://libsdl.org/) — cross-platform windowing and input
- [FreeType](https://freetype.org/) — font rendering

---

## License

MIT — see [LICENSE](LICENSE)

---

<p align="center">
  <em>Your codebase knows syntax. Your IDE should know your business.</em>
</p>
