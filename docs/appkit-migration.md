# AppKit browser migration

The default main window now uses AppKit for its split view, sidebar, search,
package table, toolbar, and Discover feed. The editorial reader, dossier/browser content, setup offers,
settings, and operation/confirmation sheets remain hosted SwiftUI views.
This is the first comparison point in the incremental migration, not a full
SwiftUI removal.

## Boundaries

- `MainWindowController` owns the native window content and toolbar.
- `SidebarController` owns grouped navigation and search. It retains outline
  items across count changes and preserves expanded groups.
- `PackageListController` owns reusable native cells, selection, loading/error
  presentation, category options, and retry. Stable package IDs drive row
  insertions/removals, targeted metadata reloads, and scroll preservation.
- `DiscoverController` owns an NSCollectionView with recycled native editorial,
  sponsored, blog, and package cards. Responsive grids preserve feed ordering,
  artwork, loading/retry states, package actions, and scroll restoration.
  Pagination starts near the bottom of the scroll view; it does not eagerly
  drain the feed. Image requests are cancelled on card reuse. Feed updates reload
  changed sections; inventory updates only refresh visible install buttons.
  The editorial reader remains a hosted SwiftUI sheet with explicit AppKit dismissal.
- Native controllers subscribe to their relevant model properties rather
  than command-output or dossier changes. Published updates are coalesced until
  the current mutation completes before reading the model.
- `MainWindowModel` retains package operations, navigation, deep links, and
  selection semantics. Filtering/sorting results are cached per list context;
  remote lists no longer rebuild the entire package index on each read.
- `HostSnapshotLoader` reads/decodes snapshots and builds indexes on its own
  actor. It caches the bundled catalog and reuses indexes for progress-only
  snapshots. Cancelling a load prevents stale publication; newer terminal output
  for the same running action survives an in-flight disk read.
- Search runs off the main actor. Superseded requests are cancelled and cannot
  publish results. Loading indicators replace the results while work is pending.
- Unchanged terminal output no longer gets reparsed when another observed
  property changes.

## Comparison

Build one Release app bundle, quit it between runs, and launch its executable:

```sh
# Default AppKit browser
"/path/to/Package Manager Manager.app/Contents/MacOS/PMMApp"

# SwiftUI browser, with the same model and background-loading improvements
PMM_SWIFTUI_BROWSER=1 "/path/to/Package Manager Manager.app/Contents/MacOS/PMMApp"
```

The flag is an evaluation/rollback path. It compares rendering architectures;
it is not a baseline for the earlier synchronous loading implementation.

Use the same Mac, window size, cached inventory/catalog, and completed background
refresh state. Record separate runs for first interactive frame, a large category,
scrolling, search, keyboard selection, and command output. Use Instruments CPU
Profiler, SwiftUI, and Hitches. Repeat and compare medians/tail latency and memory;
do not infer frame rate or latency from CPU sample counts.

Exploratory Release recordings on 2026-11-03 exercised the 6,906-entry Developer
Tools category, three pages down/up, and a `ripgrep` search. Both implementations
returned the same six search results. CPU traces were captured locally at
`/tmp/pmm-appkit-native.trace` and `/tmp/pmm-appkit-swiftui.trace`. These include
accessibility-inspection overhead and differing background remote-host activity,
so they are diagnostic artifacts, not a controlled speedup benchmark. They are
not committed to the repository.

## Validation and remaining gate

Automated regression coverage checks row insertion/removal, multi-selection,
selection restoration, retaining cells on unrelated updates, search cancellation,
and preventing an older disk load from replacing explicit inventory. Existing
core, menu-bar, and app behavior tests remain in use. The final run passed all
450 tests (262 core, 27 menu-bar, 161 app); the Release build also passed.
Pre-existing Sendable/FileManager warnings remain in PMMCore.

Manual preview checks covered installed packages, details and embedded browsing,
Cmd-click multi-selection, Cmd-F search, the large category, scrolling, and
remote loading/failure presentation and successful remote inventories. No install, update, or uninstall was executed.

Before expanding the conversion:

- Establish repeatable latency/hitch/memory results on the target Macs.
- Verify VoiceOver navigation and full keyboard access, minimum-size layout,
  appearance variants, and remote reconnect behavior.
- Profile the remaining main-actor category sort/filter on cache misses and
  terminal parsing when output actually changes. They have not been made
  incremental by changing the browser framework.
- If the browser improvement justifies continuing, convert the dossier and
  operation sheets next, reusing WKWebView/NSTextView directly. Keep
  settings/host management hosted
  until their conversion has a demonstrated benefit or full removal is desired.

## Discover follow-up (2026-11-04)

Discover now uses native collection items by default; the comparison flag still
selects the original SwiftUI page. Focused tests cover feed ordering, loading and
retry presentation, responsive sizing, reuse, and package navigation alongside
the existing feed/pagination/image-loader tests. Manual checks cover opening and
dismissing the editorial sheet, scrolling recycled cards, Details navigation,
and restoring the feed position after returning from a package.
