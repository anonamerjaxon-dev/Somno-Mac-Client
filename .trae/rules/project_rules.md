# Somno Mac Client — Agent Guidelines & Lessons Learned

> Project-wide rules of record live in `AGENTS.md` at the repo root (module
> identities, conventions, audit history). This file holds working conventions;
> where the two disagree, `AGENTS.md` wins.

## 0. Terminal commands

Use the simplest form. No pipes, no chains unless necessary.
If a command fails, give the user the raw command — don't try to fix it silently.

---

## 1. Read everything before writing anything

**Never form conclusions from partial context.** Before proposing code or writing a prompt:

1. Read ALL relevant source files in full
2. Read the design spec and plan documents
3. Read the spike/test code that proved the approach works
4. Cross-reference: does production code match what the spike proved?

When reviewing someone else's code (or an agent's output), read every line of every
file they modified. Skimming = missing bugs.

---

## 2. Agent prompts: embed the reference, don't describe it

**THIS IS THE MOST IMPORTANT RULE. IT WAS LEARNED THE HARD WAY.**

When writing a prompt for another agent to implement something:

| ❌ WRONG | ✅ RIGHT |
|---|---|
| "Phase 0 proved `kCGDesktopIconWindowLevel` + `order(.below)` works" | Include the S0.1 spike file verbatim in the prompt. The agent copies the exact window config. |
| "Use MTKViewDelegate with draw(in:) for Metal rendering" | Include the full S0.4 GameOfLifeSpike as a reference section. The agent copies the proven pipeline setup. |
| "AVPlayer loops with seek to zero" | Include the S0.5 LoopTest observer code. The agent copies the exact notification handler. |

**Rationale:** When you describe a solution, the agent re-derives it and makes new
mistakes. When you embed the working code, the agent follows the proven pattern.
The agent should NEVER re-discover what a spike already proved.

Every prompt must have a "Reference implementations" section with the actual spike code.

---

## 3. Files: don't create unless necessary

- ALWAYS prefer editing existing files over creating new ones
- NEVER create documentation files (*.md) unless explicitly asked
- NEVER create README files unless explicitly asked
- If a new file is unavoidable, check that it doesn't duplicate an existing one

---

## 4. Conventions: mimic, don't invent

Before writing code in a file, check:
- How do neighboring files handle imports?
- What naming conventions are used? (camelCase, snake_case, etc.)
- What frameworks are already in use? Don't add new ones without asking.
- How are errors handled? (throws, Result, optional, fatalError?)

Match existing patterns. Consistency beats cleverness.

---

## 5. Ask before deciding

When there's ambiguity, ask. Don't assume. Things to always ask about:

- **Library/framework choice:** Never assume a library exists. Check Package.swift.
- **Architecture decisions:** If there are two reasonable approaches, present both with tradeoffs.
- **Naming:** If a name could go multiple ways, ask.
- **Scope creep:** If a task naturally expands, check before doing extra work.

Things you CAN decide without asking:
- Local variable names (as long as they match conventions)
- Formatting (match the file you're in)
- Error messages (be specific, include context)

---

## 6. Coding habits

### General
- Write self-documenting code. Variable names should explain their purpose.
- Keep functions short. If a function exceeds ~40 lines, split it.
- Early returns over deep nesting.
- Prefer `guard` over `if` for validation at the top of a function.
- Use `let` by default. Only use `var` when mutation is needed.

### Swift-specific
- Use `final` on classes unless subclassing is intended.
- Use `private` by default. Promote to `internal` only when needed.
- Prefer structs over classes. Use classes only when identity or shared mutation is needed.
- Use protocol extensions for default implementations.
- Use `[weak self]` in all escaping closures that capture self.
- Use `fatalError` only for truly unreachable states (e.g., required init(coder:) for
  programmatic views). Prefer `throw`, `assert`, or `precondition` for recoverable errors.
- Use `switch` over long `if-else` chains. Always cover all cases.

### Metal-specific
- `framebufferOnly = false` when reading back from GPU
- `storageModeShared` for CPU-writable, GPU-readable buffers
- `dispatchThreads` with `threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)`
- Always use `drawableSize` (pixels), not `bounds` (points), for shader uniforms on Retina
- `preferredFramesPerSecond = 0` — let the display drive refresh rate

### AppKit-specific
- `wantsLayer = true` on any view that hosts sublayers
- Windows at desktop level need `order(.below, relativeTo: 0)` to avoid z-order races
- `ignoresMouseEvents = true` + `.canJoinAllSpaces` + `.stationary` for desktop canvases

---

## 7. Build verification

After ANY code change, run (from the repo root — never hardcode absolute paths):
```bash
cd desktop-canvas && swift build
```
(When working in another module, substitute that module's folder, e.g.
`cd "cursor trail" && swift build`.)

Must pass with zero errors, zero warnings. If it doesn't, fix before proceeding.
Never hand code to the user that doesn't build.

---

## 8. Commit rules

- NEVER commit unless the user explicitly asks
- NEVER push unless the user explicitly asks
- When told to commit, use descriptive messages: "Phase X: what was done"

---

## 9. Scope awareness

The current project structure (repo root is `somno mac client/`):
```
somno mac client/
├── AGENTS.md              ← canonical project rules (read first)
├── README.md
├── LICENSE
├── cursor trail/          ← SwiftPM library — mouse-cursor trail overlay
├── cursor changer/        ← SwiftPM library — personal cursor replacement
│                             (renamed from polymorph/; always call it
│                             "cursor changer")
├── desktop-canvas/        ← SwiftPM package — desktop wallpaper / procedural art
│   ├── Package.swift
│   ├── Sources/DesktopCanvas/    ← production library code
│   ├── Sources/DesktopCanvasTest/ ← test/demo executable target
│   ├── Spike/                    ← research spikes (REFERENCE, do not modify)
│   └── docs/superpowers/         ← specs and plans
├── ghost trail/           ← SwiftPM library — trails behind dragged windows
├── totem pop/             ← IMU sensor viewer app under test/ (+ docs/specs)
├── black hole/            ← REFERENCE MATERIAL ONLY — not a module to
│                             recreate, extend, or fix (see AGENTS.md)
├── .trae/, .vscode/       ← editor config (root-level, tracked selectively)
```

Work inside the module you were asked to work on unless told otherwise; root-level
files (`AGENTS.md`, `README.md`, `.gitignore`, `.vscode/`, `.trae/`) are shared —
coordinate before editing them.

---

## 10. Summary: the golden rule

**If a spike proved it, embed the spike. If you're unsure, ask. If it doesn't build, fix it.**