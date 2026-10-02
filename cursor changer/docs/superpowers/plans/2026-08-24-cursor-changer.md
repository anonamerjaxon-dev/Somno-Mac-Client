# Polymorph Implementation Plan (2026-08-24)

Spec: `docs/superpowers/specs/2026-08-24-polymorph-design.md`

## Steps

1. **Verify CGS signature** against MaCursor's Swift declarations
   (`CGSRegisterCursorWithImages` param types — CFString vs char*, ordering)
   before writing the bridge.
2. **Package skeleton** — `Package.swift` (macOS 13, tools 5.9):
   `Polymorph` lib target, `TestRunner` executable (custom harness),
   `PolymorphDemo` executable. Link AppKit/CoreGraphics.
3. **CGSBridge.swift** — dlopen/dlsym bindings (no C target needed; simplifies
   spec's interop layer), guarded symbol lookup with descriptive errors.
4. **Core library** — `CursorState` (stems + CGS names/aliases),
   `CursorTheme` (folder discovery, theme.json parse, validation,
   hotspot/size resolution: override → NSCursor.hotSpot / NSCursor.image.size
   fallback), `ThemeImageLoader` (PNG/SVG NSImage → CGImage reps at
   size×scale for scale ∈ {1,2}), `Polymorph.apply/restore`,
   `DisplayChangeMonitor`.
5. **Demo app** — SwiftUI window app: skin folder picker, Apply, Restore,
   per-state status list, auto-reapply toggle on display changes.
6. **Tuff example skin** — copy Tuff Icons (license permits use, no
   attribution required) from `~/Desktop/other related/tuff icons/3.Editing Tools`
   into `Examples/Skins/Tuff/`: arrow←cursor_default, ibeam←hand-written SVG
   (exercises SVG path), pointingHand←cursor_alternate_select,
   crosshair←cursor_precision_select, openHand/closedHand←cursor_move,
   resizeLeftRight←cursor_horizontal_resize, resizeUpDown←cursor_vertical_resize,
   operationNotAllowed←cursor_unavailable, busyAndArrow←cursor_busy,
   dragLink←cursor_link, contextMenu←cursor_help. Plus theme.json.
7. **Tests** — harness-style: state↔CGS-name mapping incl. aliases, JSON
   parsing/validation matrix, hotspot & size fallback chain, loader scaling math.
8. **Build & verify** — `swift build`, `swift run TestRunner`; fix until green.
9. **Docs** — module README (skin format, run instructions), CLAUDE.md,
   root README Planned→Existing, spec amendment note (dlsym bridge, sizes key).
