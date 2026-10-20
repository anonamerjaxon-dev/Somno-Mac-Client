# AGENTS.md — Somno Mac Client

## What this project is

A collection of personal macOS desktop-effect modules. Each top-level folder is an
independent SwiftPM package (except `black hole/` and `totem pop/` — see below).

## Module identities (IMPORTANT — read before touching anything)

- **`cursor changer/`** (renamed from `polymorph/`) — **the user's own personal cursor
  changing module.** This is not a third-party clone and not a throwaway experiment: it
  is the personal cursor-replacement tool of this project's owner. Always refer to it as
  **cursor changer** in docs and conversation (the SwiftPM package/targets/classes are
  `CursorChanger`, `CursorChangerAgent`, `CursorChangerCLI`). Its use of private
  CGS/SkyLight symbols is intentional and for personal use.
- **`black hole/`** — **reference material only.** The user placed it in the repo purely
  as a reference (Ghostty shader + tuner). It is **not a module to re-create, extend, or
  fix**. Do not modify it, and do not treat audit findings against it as work items.
  (Repo-wide hygiene that happens to cover its files — e.g. gitignore globs — is fine.)
- **`cursor trail/`**, **`desktop-canvas/`**, **`ghost trail/`** — real modules to
  maintain and fix.
- **`totem pop/`** — contains a real sensor-viewer app under `test/`; the totem animation
  from its design spec was never implemented (spec is aspirational, not a commitment).

## Audit + fix history

- Full audit report (2026-10-02): see `somno-mac-client-audit.md` (this folder — moved
  here from the session workspace on 2026-10-09); raw per-finding file:line detail in
  `somno-audit-notes.md` (same folder), with the verification pass in `verify-all.sh`.
- The P0–P2 fix round across cursor trail, desktop-canvas, ghost trail, totem pop, and
  cursor changer completed on 2026-10-02. Every module builds and runs a non-zero number
  of tests; `black hole/` was deliberately excluded (reference-only, see above).
  Commits, newest first: `f3b74f1` docs/spikes absolute paths, `06bbaed` desktop-canvas
  (build + 112 tests), `37455f8` cursor changer (209 assertions), `4377b02` cursor trail
  (46 tests), `d86ed75` cursor trail build.sh, `17b1afc` totem pop HID lifetime,
  `73e1ceb` ghost trail (12 tests), `75c1fb8` the polymorph → cursor changer rename,
  `a86f865` repo hygiene.

### Ghost trail rewrite (2026-10-03)

`ghost trail/` was rebuilt from the inside out at the user's request — it was
"taking up so much energy", inefficient, and its per-sample alpha stamping read
as a grey smudge. Package name, module name, and public builder API are
unchanged; the internals are new. Now 47 tests in 8 suites.

**Read `ghost trail/REWRITE-NOTES.md` before changing the overlay level, the
hole-clipping code, or the motion classifier.** It records the measurements that
killed the obvious designs, the most important being:

- macOS **does not composite** overlay content below `kCGNormalWindowLevel`
  (measured: 475 screenshot pixels at `kCGDesktopIconWindowLevel` vs 320,475 at
  normal). The overlay therefore sits at normal + 1 and **draws** the
  "passes behind windows" illusion by erasing ribbon pixels under visible
  windows. A screenshot of a ribbon over a busy desktop can look empty; that is
  the feature working, not a bug.
- Holes must be an even-odd **clip region**, never extra subpaths on the ribbon
  path — ribbon sections overlap, so even-odd parity-counts the ribbon against
  itself.
- A resize is never a snap. Only translation can be a window snapping.

`Examples/GhostTrailProbe` is committed deliberately: "the trail doesn't show
up" is the one failure mode unit tests cannot catch. It is proven to start the
tap and produce a live trail (`peakTrails=1`); live *pixel* proof is still
outstanding and is called out in REWRITE-NOTES.md §7.

## Conventions

- No new dependencies; SwiftPM only.
- `swift test` must actually execute tests (a suite that compiles but never runs counts
  as broken — that bug class was found and fixed in this repo once already).
- Verify claims in READMEs against code before documenting them.
- Never hardcode absolute paths from other machines (old scripts referenced an
  absolute Desktop/claude workspace path with literal spaces inside it that never
  existed — treat any such path as a false lead).
