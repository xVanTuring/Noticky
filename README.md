# Perch

English · [简体中文](./README.zh-CN.md)

> Native macOS sticky notes — menubar-resident, global hotkey capture, multi-window floats, Markdown, iCloud sync.

Perch is a native sticky-notes / quick-capture app for macOS 15+. No Dock
icon — it lives in the menu bar and stays out of the way until you need it.

<p align="center">
  <img src="docs/screenshots/menutray-open.png" width="340" alt="Menu bar tray">
  &nbsp;&nbsp;
  <img src="docs/screenshots/stack.png" width="255" alt="Floating sticky note">
</p>
<p align="center">
  <img src="docs/screenshots/manage-all-note.png" width="760" alt="Manager window">
</p>

---

## Features

### Floating sticky notes
- 6-color palette (yellow / pink / blue / green / purple / gray); the default
  color for new notes is configurable in Settings.
- Three layout modes (menubar → Layout):
  - **Free** — place anywhere
  - **Stack** — cascade; selecting a note slides it to the bottom for full visibility
  - **Tile** — auto-arranged grid; drag a note to reorder
- The **Pin** flag doubles as "auto-restore on next launch" — quitting the app
  doesn't lose your working set.
- Each note remembers its own window position and size.
- **Float on top** (menubar toggle) keeps every floating note above other windows.
- Double-click the title bar to collapse (toggleable in Settings).
- Inactive notes fade for less visual noise (toggleable in Settings).

<p align="center">
  <img src="docs/screenshots/stack-animation.gif" width="300" alt="Stack layout — the selected note slides to the bottom"><br>
  <sub><b>Stack</b> — selecting a note slides it to the bottom for full visibility</sub>
</p>
<p align="center">
  <img src="docs/screenshots/tile-animation.gif" width="840" alt="Tile layout — drag a note to reorder"><br>
  <sub><b>Tile</b> — auto-arranged grid; drag a note to reorder</sub>
</p>

### Editor
- Plain text and Markdown modes.
- Markdown rendering via [gonzalezreal/Textual](https://github.com/gonzalezreal/textual),
  with one-tap toggle between rendered view and edit mode.
- Global font size (12–24, applied live to every open window).
- New notes can start in edit mode or stay rendered, your choice.

### Quick Capture (global hotkey)
- Default `⌘⇧N`, customizable in Settings → Shortcuts
  (powered by [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)).
- Three capture sources:
  - **AX + whitelist** — read the selected text from the frontmost app via the
    Accessibility API (requires permission).
  - **Clipboard only** — pre-fill with the current clipboard contents.
  - **Disabled** — open a blank capture window.
- Whitelist is configured per app; selected-text reading is only invoked for
  whitelisted apps.

### Manager window
- Sidebar: All Notes / your custom groups / Ungrouped / Trash.
- Drag-and-drop notes into groups (multi-select drag follows the selection).
- Full-text search.
- Create / rename / move groups via right-click.
- Multi-select bulk operations: change color, pin/unpin, open as floating
  (capped at 8 to avoid screen clutter).

### Trash
- Deletions are soft — items go to Trash.
- On launch, items older than N days (default 30, configurable 7–365 in Settings)
  are purged for real, matching the behavior of macOS Notes / Mail.

### Import / Export / Backup
- Single-note Markdown export (`.md`), or batch-export multiple notes to a folder.
- File menu: full-database backup / restore as a single JSON file.
- Restore is **non-destructive** — it dedupes by UUID and skips notes already
  present, so it never overwrites your current data.

### iCloud sync (optional)
- Off by default. Toggle in Settings → iCloud Sync; first-time enable requires a
  restart.
- Once enabled, runs live cross-Mac sync.
- Verified working with China iCloud (`gateway.icloud.com.cn`).

### Localization
- Bundled English and Simplified Chinese; follows the system locale by default,
  can be forced in Settings → General.

### Data safety
- On store load failure, Perch **never silently nukes the database** — it backs
  up your data to `~/Desktop/Perch-Recovery-{ts}/`, shows a critical alert, and
  quits, so a corrupt store never costs you your notes.
- Data migration across app updates is automatic and always on.

---

## Requirements

- macOS 15.0+

---

## Acknowledgements

- [gonzalezreal/Textual](https://github.com/gonzalezreal/textual) — Markdown rendering.
- [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) —
  global hotkey recording and persistence.

---

## Development

Building from source, project layout, packaging & release, and the CloudKit
schema workflow are documented in **[DEV.md](./DEV.md)** (architecture
deep-dive in [CLAUDE.md](./CLAUDE.md)).

---

## License

© 2026 xVanTuring.
