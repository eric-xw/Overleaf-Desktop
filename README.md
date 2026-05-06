# Overleaf Desktop

A native macOS app for syncing [Overleaf](https://www.overleaf.com) projects to your local filesystem via Overleaf's Git bridge. Edit `.tex` files in your editor of choice; sync manually with one-click Pull / Push, or enable near-real-time auto-sync (~30 s end-to-end).

Built with SwiftUI. No Electron, no embedded browser — just a thin native shell over `git`.

## Why this exists

Overleaf has no official desktop client. The web app is great, but if you want to:

- Edit in Cursor / Claude Code / VS Code / Vim / TeXShop with your own extensions and keybindings
- Have offline access to your `.tex` source
- Use your own version control workflow alongside Overleaf
- Compile locally with `latexmk`

…you have to manually `git clone` each project from the command line. This app puts that workflow behind a Mac-native UI.

## Requirements

- **macOS 14 (Sonoma) or newer**
- **A paid Overleaf plan** (Standard, Professional, or institutional Premium) — the Git bridge is not available on free accounts
- **Xcode Command Line Tools** (`xcode-select --install`) — Swift 5.9+ and `git` come bundled
- An Overleaf [Git authentication token](https://www.overleaf.com/user/settings)

Full Xcode is **not** required. The build uses Swift Package Manager and a shell script to assemble the `.app` bundle.

## Install

```sh
git clone https://github.com/eric-xw/Overleaf-Desktop.git
cd Overleaf-Desktop
./build.sh run
```

`build.sh` produces `OverleafDesktop.app` in the project root. Drag it to `/Applications` if you want it in Spotlight permanently.

Build options:

```sh
./build.sh         # release build
./build.sh debug   # debug build
./build.sh run     # release build, then launch
```

## First-time setup

1. Generate a Git authentication token at [overleaf.com → Account Settings → Git authentication tokens](https://www.overleaf.com/user/settings).
2. Open Overleaf Desktop, press `⌘,` to open Settings, and paste the token. It is stored in the macOS Keychain.
3. Press `⌘N` to add a project. Paste any Overleaf project URL — for example `https://www.overleaf.com/project/65abc…`. The app extracts the project ID, clones the repo to `~/Overleaf/<name>/`, and tracks it.

## Usage

Each tracked project shows in the main list with:

- **Status badge** — `clean` / `uncommitted`, plus `↑N` / `↓N` for ahead/behind upstream
- **Conflict badge** — orange `conflict` button appears when a pull lands in a rebase conflict; click it to open the resolution sheet
- **Pull** — `git pull --rebase --autostash`
- **Push** — stages all changes, commits with `"Update from Overleaf Desktop"`, then pushes
- **More menu** — open folder in Finder, open main `.tex` in default editor, open project in browser, resolve conflict, remove from app

Settings cover the Git authentication token, manual sync defaults, and the real-time auto-sync toggles described below.

## Real-time sync

Manual Pull / Push always works, but if you're collaborating with coauthors who keep editing on overleaf.com, you can enable two background features that keep the local copy and the web copy converged automatically:

- **Pull automatically in the background** — runs `git pull --rebase --autostash` on every project at a configurable interval (10–600 s, default 30). Skips any project that's already busy or in conflict.
- **Push automatically a few seconds after each save** — a per-project `FSEventsWatcher` watches the project tree (ignoring `.git/`), debounces 3 s after the last save, then commits and pushes. If the push is rejected as non-fast-forward (a coauthor pushed in the meantime), it pulls and retries once.

Both default to **off** so the manual workflow is unchanged until you opt in. With both on at 30 s, end-to-end latency between you and your coauthors is roughly:

- **Local edit → overleaf.com**: 3–5 s (auto-push debounce + push)
- **Coauthor's web edit → your disk**: up to 30 s (auto-pull tick)

This is **not** Overleaf-web's sub-second collaborative editing — that uses an Operational Transform protocol over WebSockets that isn't exposed via the Git bridge. Replicating it would mean reverse-engineering an undocumented protocol. For asynchronous research writing, the 30 s ceiling is invisible; for two people typing in the same paragraph at the same time, it isn't a substitute for the web editor.

### Conflict handling

When auto-pull (or manual Pull) lands in a rebase conflict because both sides edited the same lines:

1. The project row gets an orange **conflict** badge.
2. Auto-pull and auto-push both pause for that project until the conflict is resolved.
3. Click the badge → resolution sheet lists conflicted files. Click **Open** on each to edit it (find `<<<<<<<`, `=======`, `>>>>>>>` markers, choose the version you want, save).
4. Click **Mark Resolved & Continue** to run `git rebase --continue`, or **Abort Pull** to discard the pull attempt and keep your local changes.

The app refuses to auto-anything on a conflicted project until you've explicitly resolved or aborted, so it can't compound the problem on its own.

## Recommended editing workflow

Overleaf Desktop only handles sync — you bring your own editor. The combination that makes this app worth using over the Overleaf web UI is **AI-assisted local editing**. Two tools work especially well together:

### Cursor (for day-to-day writing)

[Cursor](https://www.cursor.com) is a VS Code fork with built-in AI. Tab-autocomplete is the killer feature for LaTeX — it picks up your math notation, `\cite{}` keys, and repetitive environments and completes them naturally. `⌘K` inline edit handles "tighten this paragraph" / "convert this list to an `itemize`" without leaving the line.

```sh
cursor ~/Overleaf/<your-project>
```

Recommended extensions:

- **LaTeX Workshop** — syntax, error parsing, optional live PDF preview (the preview needs a local TeX install like [MacTeX](https://www.tug.org/mactex/), ~4 GB; skip it if you'd rather just use Overleaf's web compiler)
- **LTeX** or **Grammarly** — grammar/style on the prose itself

### Claude Code (for cross-file work)

[Claude Code](https://claude.com/claude-code) is an agentic CLI that's better than any IDE chat for tasks that span the whole project. Open a terminal in the project root:

```sh
cd ~/Overleaf/<your-project>
claude
```

Then ask things like:

- *"Rewrite section 3 to match the tone of section 2."*
- *"Find every `\ref{}` whose label is never defined, and every `\label{}` that's never referenced."*
- *"Audit `references.bib` for duplicate entries and suspicious DOIs."*
- *"Convert all `\textbf{}` emphasis to `\emph{}`, but not inside figure captions."*
- *"Move every figure into a `figures/` subfolder and update the `\includegraphics` paths."*

These are tedious in a normal editor and trivial for an agent loop.

### Putting it together

A typical writing session:

1. **Pull** in Overleaf Desktop to grab any web edits.
2. `cursor ~/Overleaf/<paper>` and write with Tab + `⌘K`.
3. Split terminal → `claude` for any multi-file rewrite.
4. **Push** in Overleaf Desktop when you stop for the day.

### One real gotcha

If you edit in **both** Cursor/Claude Code and the Overleaf web UI in the same session, you will hit merge conflicts on the next Pull. Pick one source of truth per session — either close the web tab while writing locally, or skip the local edit and use the web editor that day. Solo workflows rarely run into this once you internalize it.

### What to skip

- **TeXShop / vanilla VS Code** — fine editors, but you lose the AI assist that's the whole reason to sync locally. If you wanted a pure native LaTeX editor with no AI, this app's value proposition is thin.
- **Mixing AI tools mid-document** — Cursor and Claude Code both work great, but flipping between them on the same paragraph produces inconsistent style. Use Cursor for prose-level editing, Claude Code for project-level operations, and don't cross the streams.

## How it works

```
+--------------------------------+
|  SwiftUI views                 |
|  Projects / Settings /         |
|  Add Project / Conflict sheet  |
+--------------+-----------------+
               |
               v
+--------------------------------+        +------------------------+
|  AutoSyncManager               |<------>| FSEventsWatcher        |
|  - per-project lock            |        | per-project, debounced |
|  - background pull timer       |        | (auto-push trigger)    |
|  - SyncState (busy/conflict)   |        +------------------------+
+--------------+-----------------+
               |
               v
+--------------------------------+        +------------------------+
|  GitService                    |<------>| Overleaf Git bridge    |
|  - shells to /usr/bin/git      |        |  git.overleaf.com      |
|  - GIT_ASKPASS for auth        |        +------------------------+
|  - rebase continue / abort     |
+--------------+-----------------+
               |
               v
+--------------------------------+        +------------------------+
|  ProjectStore (JSON list)      |<------>| ~/Library/Application  |
|  KeychainService (token)       |        |  Support + Keychain    |
+--------------------------------+        +------------------------+
```

Auth uses `GIT_ASKPASS` rather than embedding the token in URLs or in `git config`. For each git operation, the app:

1. Writes a short shell script to a temp file (mode `0700`) that echoes `$OVERLEAF_GIT_TOKEN`.
2. Runs `git` with `GIT_ASKPASS=<that path>` and `OVERLEAF_GIT_TOKEN=<token from Keychain>` in the environment.
3. Deletes the temp script.

The token never touches `argv`, the URL, the shell history, or any persistent config file outside the Keychain.

## Project layout

```
overleaf-desktop/
├── Package.swift
├── build.sh                          # builds + assembles .app bundle
└── Sources/OverleafDesktop/
    ├── OverleafDesktopApp.swift      # @main entry, menu commands
    ├── Models/
    │   ├── Project.swift
    │   └── ProjectStore.swift
    ├── Services/
    │   ├── KeychainService.swift
    │   ├── GitService.swift
    │   ├── OverleafURLParser.swift
    │   ├── AutoSyncManager.swift     # background pull + auto-push controller
    │   └── FSEventsWatcher.swift     # debounced fs watcher
    ├── Views/
    │   ├── ContentView.swift
    │   ├── ProjectsView.swift
    │   ├── AddProjectView.swift
    │   ├── SettingsView.swift
    │   └── ConflictResolutionView.swift
    └── Resources/
        └── Info.plist
```

## Known limitations

- **No project-list discovery.** Overleaf does not expose a public "list my projects" API, so projects are added one URL at a time. Keep an Overleaf tab open to copy URLs from.
- **Generic commit messages.** Manual push uses `"Update from Overleaf Desktop"`; auto-push uses `"Auto-sync from Overleaf Desktop"`. If you want per-push messages, edit the relevant action in `AutoSyncManager.swift`.
- **No local PDF compilation.** Use Overleaf's web compiler, or run `latexmk` locally if you have a TeX install.
- **Ad-hoc code signing.** The build script signs the app with `codesign --sign -`. Gatekeeper may warn on first launch — right-click → Open to bypass. For distribution outside your own machine, you'll need a Developer ID.
- **Near-real-time, not real-time.** Auto-sync is ~30 s end-to-end via Git. Overleaf-web's sub-second collaborative editing uses an OT-over-WebSocket protocol that isn't exposed publicly; replicating it is out of scope.

## Roadmap ideas

Open to PRs:

- Per-push commit messages (prompt on manual Push, leave auto-push generic)
- Per-project sync overrides (e.g. disable auto-sync on a single noisy project)
- Diff preview before auto-push fires
- Menu-bar mode (run in the background with a status icon, no main window)
- Project-list scraping via embedded WKWebView (best-effort; may break when Overleaf changes their UI)
- Linux / Windows ports (would need a non-SwiftUI rewrite)

Already shipped:

- ~~File watcher for auto-push on save~~ ✓ v0.2.0
- ~~Background auto-pull on a timer~~ ✓ v0.2.0
- ~~Conflict resolution UI~~ ✓ v0.2.0

## Contributing

PRs welcome. Keep the dependency surface minimal — SwiftUI + Foundation + AppKit + system `git` is the whole stack today, and that's a feature.

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer

Not affiliated with Overleaf or Writelatex Limited. "Overleaf" is a trademark of its respective owner. This app is an independent client that uses Overleaf's documented Git bridge.
