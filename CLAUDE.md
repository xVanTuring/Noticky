# Noticky — macOS sticky notes

AppKit shell + SwiftUI content via `NSHostingController`, Core Data backed,
xcodegen-managed Xcode project. macOS 15+, Swift 5.0, `LSUIElement = true`
(menubar app, no Dock icon, no main menu in menu bar).

## Build & run

```sh
# Regenerate Noticky.xcodeproj from project.yml (after adding/moving files,
# or pulling from a fresh checkout — .xcodeproj is gitignored).
xcodegen

# Build (Debug)
xcodebuild -project Noticky.xcodeproj -scheme Noticky -configuration Debug build 2>&1 \
    | grep -E "(error:|BUILD )" | tail -10

# Run binary directly (so we can capture stderr, see "GUI debug" below)
APP=$(find ~/Library/Developer/Xcode/DerivedData \
    -path "*Noticky*/Build/Products/Debug/Noticky.app/Contents/MacOS/Noticky" \
    2>/dev/null | head -1)
pkill -f "Noticky.app/Contents/MacOS/Noticky" 2>/dev/null
"$APP" > /tmp/noticky.log 2>&1 &
disown

# Quit cleanly (so applicationShouldTerminate runs)
osascript -e 'tell application "Noticky" to quit'
```

## Source layout

```
Sources/Noticky/
├─ App/                  # NotickyApp (SwiftUI App), AppDelegate, MenuBarController
├─ Persistence/          # PersistenceController (programmatic NSManagedObjectModel),
│                        # Note, NoteGroup
├─ Features/
│  ├─ Floating/          # Sticky note windows (StickyPanel, FloatingNoteWindow,
│  │                       StickyPalette)
│  ├─ Notes/             # Editors: PlainTextEditor (NSTextView wrap),
│  │                       MarkdownNoteEditor (Textual + edit toggle)
│  ├─ Capture/           # Quick-capture window + Carbon global hotkey
│  ├─ Manager/           # Centralized management window (NavigationSplitView)
│  └─ Settings/          # NSTabViewController-based settings + SwiftUI tabs
└─ Resources/            # Info.plist, entitlements
```

## Architectural choices

- **AppKit shell, SwiftUI inside**. `NSWindow` / `NSPanel` for system behaviors
  (window levels, Spaces, menubar, NSStatusItem). SwiftUI for content via
  `NSHostingController`. **Don't fight this** — full SwiftUI lifecycle (no
  `@NSApplicationDelegateAdaptor`-only) loses too much AppKit access.
- **Programmatic Core Data model** (no `.xcdatamodeld` bundle). See
  `PersistenceController.makeModel()`. Lightweight migration is enabled
  (`shouldInferMappingModelAutomatically`); failure path nukes + recreates
  the store. Acceptable for dev; will need versioned model before App Store.
- **`Note.isPinned` doubles as "auto-show on launch"**. `applicationShouldTerminate`
  sets `floating.isTerminating = true` so `windowWillClose` skips clearing it.
- **xcodegen as project file authority**. `project.yml` is tracked, `*.xcodeproj/`
  ignored. Adding a new `.swift` file? It's auto-globbed; just rerun `xcodegen`.

## Settings storage

- UserDefaults keys live in `SettingsKey` enum (`Sources/Noticky/Features/Settings/SettingsView.swift`).
- Don't sprinkle string keys; add to the enum.
- `floatOnTop` is owned by `FloatingNotesRegistry`, not @AppStorage (it has
  side effects: must update all open windows on toggle).

## Window framing

- Sticky positions/sizes persisted on each `Note` (`frameX/Y/W/H + hasSavedFrame`).
- `windowDidMove`/`windowDidResize` debounce 250ms before write.
- `windowWillClose` cancels pending + flushes synchronously.
- On show, restore saved frame only if it intersects a visible `NSScreen`;
  otherwise cascade from screen center.

## GUI debug (no UI access)

```sh
# stderr capture is reliable; unified `log show` drops NSLog from LSUIElement apps.
"$APP" > /tmp/noticky.log 2>&1 &
# Add NSLog("Noticky <event>: …") at suspect spots.

# For window state: enumerate NSApp.windows and log frame/isVisible/level.
# For schema/data state, inspect the sqlite directly:
sqlite3 "$HOME/Library/Containers/app.noticky.Noticky/Data/Library/Application Support/Noticky/Noticky.sqlite" \
    "SELECT Z_PK, ZISPINNED, substr(ZCONTENT,1,40) FROM ZNOTE;"

# Crash reports: ~/Library/Logs/DiagnosticReports/Noticky-*.ips
```

## Repeating gotchas (pointers — full notes in `~/.claude/projects/.../memory/`)

- **Do not delete a Core Data object inline while a SwiftUI `@ObservedObject`
  watches it** — guard `body` with `if note.isDeleted { EmptyView() }` AND
  defer `context.delete()` to next runloop tick.
- **`NSPredicate(format: "x == YES")` does not work in Swift** for boolean
  attributes — must be `NSPredicate(format: "x == %@", NSNumber(value: true))`.
- **`SourceKit "Cannot find type"` errors on every save are noise** for this
  project (programmatic model, single-module). Trust `xcodebuild` output, not
  inline diagnostics.
- **`window.performClose(nil)` is a no-op on borderless windows** (no
  `.closable` styleMask). Use `window.close()` directly.
- **`NSHostingController` shrinks its host `NSWindow` to the SwiftUI view's
  intrinsic size**. After assigning `contentViewController = host`, always
  call `window.setContentSize(...)` once. Don't also set SwiftUI `.frame()`
  or `host.preferredContentSize` — three constraints triggers Auto Layout
  infinite loop crash.
- **Settings window: SwiftUI `Settings { SettingsView() }` + `TabView`**.
  Free on macOS 14+: toolbar tabs with icons, top-anchored window resize
  between tabs, ⌘, binding. **No height animation** though — tab switches
  snap. Getting the System Settings.app animation back requires
  `NSTabViewController` subclass + `NSAnimationContext.runAnimationGroup`
  + manual top-anchor `window.animator().setFrame(...)`, plus an
  `NSEvent.addLocalMonitorForEvents` for ⌘, since AppDelegate can't
  intercept SwiftUI's binding. We chose the clean SwiftUI path over the
  animation. From the menu bar trigger Settings via
  `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`.

## Commits

Per Noticky-specific authorization (see memory `feedback_noticky_commits_autonomous.md`),
commits are made autonomously by Claude after each semantically complete change.
One change = one commit. No auto-push, no destructive git ops without user OK.
