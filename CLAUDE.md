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
- **Programmatic Core Data model** (no `.xcdatamodeld` bundle), versioned via
  `Persistence/Schema/SchemaV{N}.swift` + `CoreDataSchema` registry. Each schema
  version has its own builder; `SchemaVersion.current` is the head. Lightweight
  migration is on (`shouldInferMappingModelAutomatically`) — handles 99% of
  changes (add/remove fields, renames with `renamingIdentifier`, add entities).
  Load failure no longer nukes — backs up sqlite/shm/wal to `~/Desktop/
  Noticky-Recovery-{ts}/` and shows critical NSAlert before quitting.
  **Adding a new schema version**: copy `SchemaV1.swift` → `SchemaV2.swift`,
  edit only V2, add `case v2` to `SchemaVersion`, set `current = .v2`.
  **Never edit a published version** — its hash is baked into user sqlites.

## Schema → CloudKit deployment workflow

When bumping `SchemaVersion.current` (e.g., V1 → V2):

1. **Local migration**: lightweight migration handles user sqlites automatically
   on first launch with the new build. No user action.
2. **Verify the migration code path** before tagging release:
   Settings → iCloud Sync → "Run migration self-test" (DEBUG build).
   Builds a synthetic prior version, writes sample data, migrates forward,
   asserts data preserved. Pass = lightweight migration handles your changes.
   Fail = either your changes need a custom mapping model, or `SchemaMigrationTester`
   itself needs a new synthetic case for the kind of change you made.
3. **Push schema to CloudKit Development**:
   Settings → iCloud Sync → "Initialize Cloud schema (Development)".
   `NSPersistentCloudKitContainer.initializeCloudKitSchema()` walks the model
   and creates/updates record types in the Dev environment of your CloudKit
   container. After success, the deployed-version label updates to the
   current `SchemaVersion`. The "Local schema differs from last push" warning
   reminds you when the field is stale.
4. **Promote Development → Production** in the CloudKit Console
   (https://icloud.developer.apple.com → your container → Schema → Deploy
   Schema Changes). **This is the only step Noticky cannot do programmatically**
   — it must happen via the web UI per Apple's CloudKit deployment model.
   Deploying anything destructive (removing fields/types from Production) is
   irreversible without losing all user cloud data.
5. **CloudKit production schema is append-only.** You can add fields/record
   types in V2; you can never remove them once deployed to Production.
   Unused fields stay in Production's schema forever.
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
sqlite3 "$HOME/Library/Containers/tech.xvanturing.Noticky/Data/Library/Application Support/Noticky/Noticky.sqlite" \
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
- **Entry point is AppKit, not SwiftUI App**. `AppDelegate` carries `@main`
  and a custom `static func main()` that runs `NSApplication.shared`. We
  do **not** use `@main struct ...: App { var body: some Scene { ... } }`
  because that requires at least one Scene, and `Settings { ... }` scene
  hijacks ⌘, via a private mechanism that beats `NSApp.mainMenu` key
  equivalent dispatch (verified: replacing mainMenu still showed SwiftUI's
  empty Settings window on ⌘,). `WindowGroup`/`Window` auto-create
  visible windows, also unwanted. So no SwiftUI App lifecycle at all.
- **Settings window is fully AppKit** (`SettingsWindowController` +
  `AnimatedSettingsTabController: NSTabViewController`). ⌘, comes from a
  hand-rolled `NSApp.mainMenu` Settings item — LSUIElement hides the
  menu bar but key equivalents still dispatch. Animation: `NSAnimationContext.
  runAnimationGroup { ctx.allowsImplicitAnimation = true; window.animator().
  setFrame(...) }` with top-anchor (`origin.y -= delta`). This matches
  sindresorhus/Settings + every other open-source mac app that wants the
  System Settings.app feel — see CLAUDE.md commits for the search trail.
  Each pane's `NSHostingController.sizingOptions = .preferredContentSize`
  bridges SwiftUI `.frame(...)` to `NSViewController.preferredContentSize`,
  so the tab controller can read the target size.

## Commits

Per Noticky-specific authorization (see memory `feedback_noticky_commits_autonomous.md`),
commits are made autonomously by Claude after each semantically complete change.
One change = one commit. No auto-push, no destructive git ops without user OK.
