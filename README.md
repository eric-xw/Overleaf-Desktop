<p align="center">
  <img src="assets/logo.png" alt="Overleaf Desktop" width="160">
</p>

<h1 align="center">Overleaf Desktop</h1>

<p align="center">
  Native macOS app that syncs <a href="https://www.overleaf.com">Overleaf</a> projects to your local filesystem via Overleaf's Git bridge. Edit <code>.tex</code> files in any editor; sync manually or with ~30&nbsp;s near-real-time auto-sync.
</p>

<p align="center">
  Built with SwiftUI. No Electron, no embedded browser — a thin native shell over <code>git</code>.
</p>

## Why this exists

Manual `git clone` + Pull / Push kills the workflow — you forget to sync, your coauthor's edits collide with yours, you give up and go back to the web editor. This app handles the sync so you can stay in your editor.

- **Auto-sync, no buttons.** Save your `.tex` and ~3 s later it's on overleaf.com. Coauthor's web edits appear on your disk within ~30 s.
- **Conflict UI.** Same-line conflicts surface as an orange badge with a one-click resolution flow, not a raw `git rebase` mess.
- **Edit anywhere.** Cursor, Claude Code, VS Code, Vim — including AI tab-autocomplete the web editor doesn't have.
- **Offline editing.** Auto-push catches up on reconnect.

## Requirements

- macOS 14 (Sonoma) or newer
- A **paid** Overleaf plan (Standard, Professional, or institutional Premium) — the Git bridge isn't on free accounts
- Xcode Command Line Tools (`xcode-select --install`); full Xcode is not required
- An Overleaf [Git authentication token](https://www.overleaf.com/user/settings)

## Install

```sh
git clone https://github.com/eric-xw/Overleaf-Desktop.git
cd Overleaf-Desktop
./build.sh run
```

`build.sh` produces `OverleafDesktop.app` in the project root. Drag it to `/Applications` to keep it in Spotlight.

## First-time setup

1. Generate a token at [overleaf.com → Account Settings → Git authentication tokens](https://www.overleaf.com/user/settings).
2. Open the app, press `⌘,`, paste the token (stored in macOS Keychain).
3. Press `⌘N`, paste an Overleaf project URL. The app clones to `~/Overleaf/<name>/`.

## Usage

Each project row shows status (`clean` / `uncommitted` / `conflict`), with **Pull** and **Push** buttons and a More menu for Finder, default editor, and removal.

Manual Pull / Push always works. In **Settings**, you can also enable:

- **Pull automatically in the background** — `git pull --rebase --autostash` on every project at a configurable interval (10–600 s, default 30).
- **Push automatically after each save** — file watcher debounces 3 s after the last save, then commits and pushes. On non-fast-forward rejection it pulls and retries once.

Both default to **off**. With both on at 30 s:

- Local edit → overleaf.com: 3–5 s
- Coauthor's web edit → your disk: up to 30 s

### Menu bar mode

Tick **Menu bar mode** at the bottom of Settings to hide the Dock icon and put a leaf icon in the menu bar instead, with **Open Overleaf**, **Settings…** and **Quit Overleaf**. Closing the window keeps the app (and auto-sync) running in the background, and later launches start straight into the menu bar with no window. If the icon is hidden (e.g. behind the notch), open the app again from Finder or Spotlight to bring the window back.

### Conflicts

When a pull hits a rebase conflict, the row gets an orange **conflict** badge and auto-sync pauses for that project. Click the badge → resolution sheet lists conflicted files → **Open** each, edit normally (look for `<<<<<<<` / `=======` / `>>>>>>>` markers), then **Mark Resolved & Continue** or **Abort Pull**.

## Editor pairing

The point of going local is using an editor with AI. Recommended combo:

- **[Cursor](https://www.cursor.com)** for line-of-sight editing — Tab autocomplete on math notation and `\cite{}` keys, `⌘K` for "tighten this paragraph". Open with `cursor ~/Overleaf/<paper>`. Add **LaTeX Workshop** for error parsing and optional PDF preview (needs MacTeX, ~4 GB; skip if you compile on overleaf.com).
- **[Claude Code](https://claude.com/claude-code)** for project-wide ops — `cd ~/Overleaf/<paper> && claude`, then ask things like *"audit references.bib for duplicate DOIs"* or *"find every `\ref{}` whose label is never defined"*. Trivial for an agent, tedious in any editor.

Don't edit in both Cursor / Claude Code and the Overleaf web UI in the same session, or you'll fight rebases.

## How it works

```
+--------------------------------+
|  SwiftUI views                 |
|  Projects / Settings / Conflict|
+--------------+-----------------+
               |
               v
+--------------------------------+        +------------------------+
|  AutoSyncManager               |<------>| FSEventsWatcher        |
|  per-project lock,             |        | per-project, debounced |
|  background pull timer,        |        | (auto-push trigger)    |
|  SyncState                     |        +------------------------+
+--------------+-----------------+
               |
               v
+--------------------------------+        +------------------------+
|  GitService                    |<------>| Overleaf Git bridge    |
|  /usr/bin/git via GIT_ASKPASS  |        |  git.overleaf.com      |
+--------------+-----------------+        +------------------------+
               |
               v
+--------------------------------+
|  ProjectStore + KeychainService|
+--------------------------------+
```

Auth uses `GIT_ASKPASS`: a temp shell script (mode `0700`) that prints the token from an env var, set up per-operation and deleted after. The token never touches `argv`, URLs, shell history, or persistent config — only the macOS Keychain.

## Project layout

```
overleaf-desktop/
├── Package.swift
├── build.sh
└── Sources/OverleafDesktop/
    ├── OverleafDesktopApp.swift
    ├── Models/{Project, ProjectStore}.swift
    ├── Services/
    │   ├── KeychainService.swift
    │   ├── GitService.swift
    │   ├── OverleafURLParser.swift
    │   ├── AutoSyncManager.swift     # auto-sync controller
    │   └── FSEventsWatcher.swift     # debounced fs watcher
    └── Views/
        ├── ContentView.swift
        ├── ProjectsView.swift
        ├── AddProjectView.swift
        ├── SettingsView.swift
        └── ConflictResolutionView.swift
```

## Known limitations

- **No project-list discovery.** Overleaf has no "list my projects" API, so projects are added one URL at a time.
- **Embedded git worktrees skipped.** Directories containing a nested `.git` (Claude Code worktrees, submodules) are excluded from commits. Add to `.gitignore` for a clean status.
- **No local PDF compilation.** Use Overleaf's web compiler, or run `latexmk` locally.
- **Ad-hoc code signing.** Gatekeeper may warn on first launch — right-click → Open. For distribution to others, you'd need a Developer ID + notarization.
- **Near-real-time, not real-time.** Overleaf-web's sub-second collaborative editing uses an OT-over-WebSocket protocol not exposed via the Git bridge.

## Roadmap

Open to PRs:

- [ ] Per-push commit messages (prompt on manual Push)
- [ ] Per-project sync overrides (disable auto-sync on noisy projects)
- [ ] Diff preview before auto-push fires
- [x] Menu-bar mode
- [ ] Linux / Windows ports (would need a non-SwiftUI rewrite)

## Contributing

PRs welcome. Keep the dependency surface minimal — SwiftUI + Foundation + AppKit + system `git` is the whole stack today, and that's a feature.

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer

Not affiliated with Overleaf or Writelatex Limited. "Overleaf" is a trademark of its respective owner. This app is an independent client that uses Overleaf's documented Git bridge.
