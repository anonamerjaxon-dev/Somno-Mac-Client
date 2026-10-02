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

- Full audit report (2026-10-02): see the session workspace file `somno-mac-client-audit.md`;
  raw per-finding file:line detail in `somno-audit-notes.md` (same folder).
- A priority fix round addresses all P0–P2 findings across cursor trail, desktop-canvas,
  ghost trail, totem pop, and cursor changer (in progress as of 2026-10-02; update this
  line with final status when done). `black hole/` is deliberately excluded
  (reference-only, see above).

## Conventions

- No new dependencies; SwiftPM only.
- `swift test` must actually execute tests (a suite that compiles but never runs counts
  as broken — that bug class was found and fixed in this repo once already).
- Verify claims in READMEs against code before documenting them.
- Never hardcode absolute paths from other machines (old scripts referenced an
  absolute Desktop/claude workspace path with literal spaces inside it that never
  existed — treat any such path as a false lead).
