# MacVoxel — The Hater's Survey

## Opening verdict

This is, irritatingly, a competent codebase. Tight scope, one developer, a
clear mental model of what each file is for, and enough discipline in the
hard parts (the path tracer, the chunked grid, the dirty-chunk dance) that
the obvious failure modes have already been thought through and survived
contact with the GPU. There's no architectural rot to scream about, no
spaghetti import graph, no godfile owning a domain it doesn't understand.

That said, `VoxelView.mm` has quietly inflated to 2,100+ lines and is
absorbing every cross-cutting concern that doesn't have a better home — tool
gestures, edit history orchestration, picking, geometry preview, rendering
glue. It's the asbestos in the walls: works fine until you try to renovate.
And the test suite is whatever Paul eyeballs in the running app, which is
the correct policy for a personal renderer right up until the first
regression that costs a weekend to bisect.

The path tracer shader is genuinely good. The grid layer is also good. The
input/UI plumbing is where the next round of pain will originate.

---

## What this codebase appears to be

Native macOS voxel editor + GPU path tracer, MagicaVoxel-shaped. C++20 +
Obj-C++, AppKit shell hand-rolled in code (no XIBs), MTKView content view,
Dear ImGui in docking branch for panels. Two renderers backed by the same
GPU layout (coarse-grid-of-chunk-indices + chunk pool, 16³ chunks): a
Lambertian ray-cast renderer for editing and a path tracer with NEE + MIS +
GGX VNDF + Beer-Lambert glass for "render mode." Single-document app,
singleton ToolState/EditHistory/Selection/Clipboard/RenderState,
version-counter-based cache invalidation between Document and renderers.
Headless `render` CLI for deterministic verification.

Roughly 14 modules in `src/`, four ImGui panels in `src/ui/`. ImGui is a
submodule. No test target in CMake. No CI configuration in the repo (or
nothing CMake exposes).

---

## The Reckoning

### Architecture and structure — mostly fine, with one growing tumor

**`VoxelView.mm` is the tumor. (Serious, growing.)** 2,125 lines spanning:
ImGui setup, dock layout, font loading, mouse/scroll/magnify routing, ray
construction, tool-mode dispatch, preview-vs-commit edit history routing,
brush stamping, line/circle/square/face shape enumeration, screen-space
projections, draw-list overlays, save-render panel orchestration, picking
fallbacks, and the `MTKViewDelegate` itself. This file is doing the work of
~6 components and the lid is starting to bulge.

Concretely:
- The shape-tool logic (Line/Circle/Square/Face) for both *enumeration* and
  *commit* lives here. `enumerateLineFromAnchorTo:`,
  `enumerateCircleFromAnchorTo:`, `enumerateSquareFromAnchorTo:`,
  `floodFaceFromCell:`, `applyFaceExtrusion:`, `applyFaceLayerAtOffset:`,
  `transitionFaceTo:` — all pure-ish geometry and edit logic that has no
  business being inside an Obj-C view class. They should live in C++ free
  functions / a `ShapeTool` namespace, with `VoxelView` as a thin client
  that hands them a grid pointer, an anchor, and a cursor.
- The shape-preview rollback/refresh state machine (`_shapePreview`,
  `_faceAppliedD`, `_faceAppliedWith`, `_faceObservedDrag`,
  `_faceSeedCells`) is a small state machine masquerading as a pile of
  ivars. It's *correct*, it just shouldn't be on a `MTKView` subclass.
  Pull it into a `ShapePreview` C++ struct that owns
  `try_emplace`/rollback semantics and stop forcing `VoxelView.mm` to
  know about flood fills.
- `Bresenham3D`, `ProjectInPlane`, `OffsetInPlane`, `UnpackCellKey` are
  free functions in an anonymous namespace — that's fine, but they want
  to live next to a `Shapes.cpp` along with the enumerators.
- Picking math (`gridRayAtPoint:`, `pickGridCellAtPoint:`,
  `computeTargetCellAtPoint:`, `computeLineEndpointAtPoint:`,
  `pickFaceAtPoint:`) reproduces the same NDC→world unproject in five
  places. Single helper, please.

**The "global singletons via `Foo& CurrentFoo()` returning `static Foo`"
pattern is everywhere.** `CurrentTool`, `CurrentHistory`,
`CurrentSelection`, `CurrentClipboard`, `CurrentRenderState`. CLAUDE.md
correctly notes this is fine for a single-document app; the moment a second
viewport / second document appears, it's a 6-file refactor. The cost of
acknowledging that now is roughly zero — wrap them in a `Session` struct
passed by reference and the call sites would be no uglier. Not a fire
today; flagging because every one of those singletons is a future
bug-multiplier that does global I/O. *Severity: annoying.*

**Document ownership is genuinely clean.** `AppDelegate` owns the
`unique_ptr<Document>`; `VoxelView` reaches for it through the delegate per
frame. Renderers cache against `doc->version`. The version counter is a
cheap, correct invalidation strategy. **Grudging compliment.**

### Code quality

- **Comments are excellent.** Almost universally explain *why*, not *what*,
  exactly as CLAUDE.md prescribes. The `kAbsorptionScale = 0.5`
  justification in `PathTraceRenderer.mm`, the `t_hit`
  parametric-distance comment, the `medium_mat` skip-mat rationale —
  these are the kind of comments that survive decade-long refactors.
  Whoever's been maintaining this discipline, keep doing it. This is the
  rarest kind of right.
- **Naming is consistent.** `kChunkBits`/`kChunkSize`/`kChunkMask`
  everywhere, PascalCase types, snake_case locals. No surprises.
- **Duplicated DDA setup between the raycast renderer's MSL, the path
  tracer's MSL, and the CPU `Raycast.cpp`.** Three implementations of the
  same Amanatides-Woo traversal with subtly different invariants (the
  MSL ones are aware of empty-chunk skip; the CPU one isn't; the
  path-trace one layers in `medium_mat` exit-reporting). The MSL ones
  can't share code cleanly (no headers across libraries), but the CPU
  `Raycast.cpp` and the shader logic are diverging and one will
  eventually disagree with the other on a face boundary. Document the
  canonical invariants in a comment block somewhere central, ideally
  with a small diagram of which side of the boundary "owns" the hit.
  *Severity: annoying now, serious if anything ever depends on CPU/GPU
  pick agreement.*
- **`_dragSkipCells` uses a packed `int64_t` key with 21 bits per axis,
  reproduced (with the unpacking helper) in three files: `Selection`'s
  pack lambda, `Raycast.h::PackCellKey`, `EditHistory.cpp::PackKey`,
  `VoxelView.mm`'s `pack`/`UnpackCellKey`.** Four definitions of the
  same encoding. Pick one, put it in a header, delete the others.
  *Severity: annoying. The encoding is identical in every copy today;
  that's how you know one of them will drift.*
- **`drawSelectionOverlay` projects 8 corners and applies hidden-line
  removal per voxel** — fine for small selections; for large ones (the
  comment acknowledges "thousands of voxels") this is per-frame O(N) on
  the CPU side with at least 8 matrix×vector multiplies each. Currently
  a paper-cut, not a wound, but if Paul ever lets a flood-fill produce a
  100k-voxel selection, the overlay is going to be the bottleneck before
  the renderer is. *Severity: nitpick, with a known cliff.*

### Correctness and safety

- **`VoxelGrid::ToChunkCoord` relies on C++20 floor-divide for negative
  coordinates** — the comment correctly flags this and `CMAKE_CXX_STANDARD
  20` enforces it. Good. Not a complaint; recognition that you knew about
  the trap.
- **`bounds_` is documented as a loose over-estimate after `Set(0)`.**
  CLAUDE.md flags this as intentional. Acknowledged. The framing-camera
  consumer in `frameCameraToDocument` will overshoot if the user ever
  permanently shrinks a model, but no current tool path does that. Live
  bomb if a Box-clear or Crop tool ever ships.
- **`UnpackCellKey` in `VoxelView.mm` uses 21-bit fields with
  two's-complement sign-extend** — this is correct for `int32_t` values
  that fit in ±2²⁰. Cell coords beyond ±~1M will silently wrap. Also the
  case for `EditHistory::PackKey`, `Raycast.h::PackCellKey`, and the
  selection overlay's `pack`. The `Bounds3` doesn't enforce this, nor
  does `VoxelGrid::Set`. Nothing today reaches that range, but it's a
  silent truncation hazard. *Severity: nitpick now, serious if
  multi-million-cell scenes ever land.*
- **Shader `pcg` stream-state is mixed by hashing pixel coords + frame
  seed** — fine for low-correlation Monte Carlo, but the
  `pcg(rng); pcg(rng);` warm-up at fragment entry is two iterations,
  which is on the light side. Probably unnoticeable; flagging because
  correlated-sample artifacts at very low samples are exactly the sort
  of thing a future "why does my smooth gradient look stripey"
  investigation will land on.
- **`Raycast.cpp` checks `tMaxX <= tMaxY && tMaxX <= tMaxZ` with `<=`
  for the X path but `<=` again for Y vs Z** — equality-on-tie keeps the
  iteration deterministic, but the order between identical-`tMax` axes
  isn't symmetric. Doesn't matter for Lambertian shading; could matter
  if someone ever uses this picker for thin slab edges where the entry
  face axis matters. *Severity: nitpick.*
- **`encodeAccumulationSampleIntoCommandBuffer:` increments
  `_sampleCount` before the GPU has finished the encode.** Fine because
  the count is read for the next frame's `loadAction` decision and for
  the display divisor, both serialised via the command queue. Just
  noting it's a load-bearing assumption.
- **`commitFaceAtPoint:` calls `applyFaceExtrusion:` after `BeginOp`
  without checking that `_faceSeedCells` is non-empty in the `d == 0`
  fallback branch.** It's checked at entry to `applyFaceExtrusion:`, so
  this is fine — but the click-as-1-layer fallback (`if (d == 0 &&
  !_faceObservedDrag) d = 1;`) duplicates the `refreshShapePreview`
  logic and the two are now joined by string. *Severity: nitpick.*

### Path tracer shader (the hot file)

This is the one place I read line by line. It holds up.

- The bounce loop's medium handling is the trickiest part of the file
  and it's correct: `entered_medium` captured before `medium_mat = 0u`,
  exit refraction running on the captured value, Beer-Lambert applied
  with parametric distance against the clipped origin, TIR vs Fresnel
  coin-flip with the symmetric Schlick form, new medium segment
  correctly re-entered on internal reflection. Good. **Grudging
  acknowledgment.**
- **`pdf_ggx_vndf` recomputes `D`, `G1_o`, and the half-vector that
  `nee_ggx_mis` already computes.** Two separate code paths build the
  same GGX terms. Consolidating into a small `GgxTerms` struct or a
  single helper would shave ~20 lines and remove a class of "did you
  remember to add `_ior` clamping in both copies" bugs. *Severity:
  nitpick.*
- **`nee_pdf_solid_for_arrival` hard-codes the area pdf as `1 / (N · 3)`** —
  i.e. uniform over lights × uniform over 3 faces. That's the same
  constant `nee_sample_light` uses, so they agree. If anyone ever
  changes the sampler (e.g. weights faces by `cos_y`), they need to
  remember to update this in lockstep, and the compiler won't warn
  them. Pull `pdf_area` out to a shared `constexpr` or a single helper.
  *Severity: annoying.*
- **`light_count == 0` short-circuit is checked in three places** — at
  NEE entry, in `nee_pdf_solid_for_arrival`, and at the BSDF-side
  emitter hit. Fine, but each one reads slightly differently. Worth a
  comment block at the top of the NEE section laying out the
  zero-light contract once.
- **`max_bounces` boundary handling for the ground plane vs voxel hit**
  is asymmetric: voxel-hit uses `if (b == u.max_bounces) break;`
  *before* it scatters, but the ground-plane path checks
  `if (b == u.max_bounces) break;` *inside* the no-hit branch. Re-reading,
  the ground-plane NEE call is gated correctly, but the reader has to do
  a double-take. Worth a one-line comment.
- **`prev_is_delta` semantics**: the comment is good. The mechanics are
  good. The set of branches that touch it is now eight (camera primary,
  emissive arrival, exit-refraction, glass Fresnel reflect, glass
  transmit-refract, glass TIR, glass diffuse-fallback, metal specular,
  metal diffuse, plain diffuse). Each branch sets `prev_is_delta` to a
  literal. If a future material type forgets, the bug is silent. Worth
  a small `BounceResult` struct that *requires* setting the field.
  *Severity: annoying.*
- **`fragment` function takes 6 buffers + 1 texture and is a 380-line
  monolith.** That's how path tracers tend to look; not a critique,
  just recognition that this file is approaching the limit of what's
  readable inline. A second pass to extract the per-material scatter
  into named device-functions (`scatter_metal`, `scatter_glass`,
  `scatter_diffuse`) would be welcome. *Severity: annoying, getting
  worse with each new material the codebase will inevitably add.*
- **The `kShaderSource` is a big NSString literal in `.mm`** — it
  works, it's deterministic, and you lose syntax highlighting. The
  trade-off is fine for now. If it grows past 2000 lines, splitting it
  into a `.metal` source file and loading via `MTLLibrary` from a
  runtime path is the obvious next step.

### Testing

There is no test target. There are no `.cpp` test files I can find. The
`test/vox/` directory holds sample inputs the headless renderer eats,
which is something but not testing. The only verification mechanism
documented is "render a scene with `--seed 1` and `md5` the PNG." That's
a perfectly fine *regression* tool — but it tests the entire stack at
once, so a failure points at "something broke" with no narrowing.

What's missing, in rough order of how-much-I-care-tier:

1. **`VoxelGrid` unit tests.** Set/Get round-trip, dirty-chunk
   accumulation, neighbor-bump on chunk-boundary edits, chunk eviction
   when `filled_count` drops to zero, bounds tightness/looseness
   contract. This is the most-load-bearing data structure in the app
   and the easiest to test. (Catastrophic gap — the kind of thing a bad
   refactor of `Set()` could quietly break for a year.)
2. **`EditHistory` unit tests.** Same-cell coalescing, redo
   invalidation on new op, kMaxOps eviction, undo→redo→undo
   idempotence. Trivial to write; the `current_index_` map is the kind
   of optimisation that silently regresses.
3. **`VoxFile` round-trip tests.** Load → mutate → save → reload →
   structural compare. The sample `.vox` files in `test/vox/` are the
   inputs; the test is two LoadVox calls and a grid+palette equality
   check. Without this, a MagicaVoxel format spec change will land in
   prod and you'll find out from a user.
4. **`Camera` math tests.** Frame-to-bounds determinism, Orbit pitch
   clamp, Zoom range clamp.
5. **Headless render hash test in CI.** The user already has the
   primitives — `--seed 1` + md5 — they just don't have CI.

CLAUDE.md says "test the change in the running app before reporting
done" which is honest and correct for renderer/UI work, but it does not
absolve the code from having unit tests for non-rendering data
structures. *Severity of the testing gap: catastrophic, in the sense
that any refactor of `VoxelGrid` or `EditHistory` is currently a leap
of faith.*

### Dependencies

- ImGui (docking branch) as a submodule. Sane.
- System frameworks only otherwise (Metal, MetalKit, Cocoa, simd,
  ImageIO, UTI, GameController, QuartzCore). No supply-chain surface
  area worth worrying about.
- No vendored libpng, libjpeg, etc. — `ImageIO` does the PNG work. Good
  call.

Nothing to complain about. This is the cleanest dependency graph I've
seen on a graphics project this year.

### Performance and scalability

- **`RaycastRenderer` does incremental dirty-chunk uploads with bounds
  padding (`kPaddingChunks = 4`), pool-doubling growth, and palette
  fingerprinting to skip redundant uploads.** This is the kind of
  careful engineering that makes the editor feel responsive, and the
  comments explain exactly why each piece exists. **Grudging
  acknowledgment.**
- **`PathTraceRenderer::rebuildResourcesFromDocument` is wholesale on
  every doc.version bump.** Acceptable because path-trace mode is for
  stationary renders, not live editing — the comment says so. Document
  what threshold of edits would change this calculus (e.g. if you add an
  emissive Live Preview mode, this rebuild is going to bite).
- **`PathTraceRenderer::rebuildResourcesFromDocument` builds the light
  list with a triple-nested loop over every voxel of every filled
  chunk** for every doc.version change, which means every edit. On an
  emitter-heavy scene with thousands of emissive voxels and active
  editing, this is O(filled_chunks × 4096) per edit. Today path-trace
  mode and edit mode are disjoint, so it's a non-issue. The day someone
  toggles "render while I work" it becomes a serious issue. *Severity:
  nitpick today, serious if PT becomes interactive.*
- **`AppDelegate::deleteSelection:` and `paste:` walk the entire
  selection box with `grid.Get` per cell** — for a large selection
  that's `O(volume)` lookups against the chunk hashmap. Fine for
  human-sized selections; degrades on procedurally-generated ones. A
  chunked walk (iterate the chunks the box overlaps, skip empty ones)
  would be `O(intersected_chunks × 4096)`. Same big-O for dense
  selections; way better for sparse. *Severity: annoying.*
- **`Selection::voxels` is a `std::vector<std::array<int32_t, 3>>`.**
  Three `int32_t` per voxel = 12 bytes. For a 100k-voxel sparse
  selection that's 1.2 MB; fine. A million voxels and the selection
  overlay's per-frame iteration starts dominating. Good enough for now;
  not future-proof.

### Security posture

It's a local desktop app that opens files the user explicitly chose.
There's no network, no IPC, no untrusted input vector beyond `.vox`
parsing. The `VoxFile.cpp` reader does bounds checks on `Read(n)` /
`Skip(n)` / `ReadString` (size validated against `remaining()`), which
is the right shape — but the dictionary parser at line 61 reads `n` as
an `int32_t` with only the `n < 0` check. A malicious `.vox` could
specify `n = INT32_MAX` and then the loop iterates that many times
reading strings; each `ReadString` will fail when `n > remaining()`,
but you'd have spent CPU time getting there. Not a security hole, but
a fuzz target.

I didn't audit every `Read` call. Run a fuzzer (libFuzzer or AFL) over
`LoadVox` for a weekend if you ever distribute prebuilt binaries.
*Severity: nitpick for a personal-use editor; serious if this ever
ships to non-technical users.*

### Operational maturity

- **Logging is `fprintf(stderr, ...)`.** That's the right answer for a
  desktop app that's "open Console.app and see what's happening." No
  complaints.
- **`imgui.ini` is persisted to `~/Library/Application
  Support/MacVoxel/`.** Correct location, correct lifecycle (static C++
  string outliving ImGui).
- **No crash reporter, no telemetry.** Fine; it's a personal project.
- **Headless `render` subcommand is exemplary.** Deterministic seed,
  stderr progress, exit codes, named arguments. CLAUDE.md says "use
  this instead of asking Paul to eyeball the running app" and that's
  the correct policy.
- **No CI.** Build configuration is reproducible; nobody is verifying
  it builds clean on a fresh machine. Adding a single GitHub Action
  that runs `cmake -B build -G Ninja && cmake --build build` would
  catch a surprising fraction of "I forgot to commit the .h" mistakes.

### Documentation and onboarding

`CLAUDE.md` is genuinely good — it explains the system, the
conventions, the path-tracer-specific invariants, the things that look
weird but are intentional. A new contributor reading just `README.md` +
`CLAUDE.md` could orient themselves in an afternoon. **Grudging
acknowledgment.**

One critique: **`CLAUDE.md` is stale on path-tracer features.** It says
"What the path tracer doesn't have yet: Next-event estimation / direct
light sampling." NEE clearly exists in `PathTraceRenderer.mm` —
`nee_sample_light`, `nee_diffuse_mis`, `nee_ggx_mis`, `light_count`,
`GpuLight`, `lights[5]`, the whole apparatus. ACES tonemap also exists
(`display_fragment` with `aces_tonemap` flag). The "doesn't have yet"
section needs an update. This matters because the document's
load-bearing claim is "treat me as authoritative on what exists," and
right now it isn't. *Severity: annoying, but it actively misled me
during this survey for about ten minutes.*

### Tooling and CI/CD

- `compile_commands.json` exported, clangd-friendly. Good.
- `-Wall -Wextra -Wpedantic -Werror` for project sources. Good.
- `-fobjc-arc` for ObjC++. Good.
- ImGui sources compiled with `-Wno-everything` to keep their warnings
  out of the project's build log. Reasonable.
- No `.clang-format` checked in. The code is formatted consistently
  enough that I doubt it matters in practice, but the next contributor
  has to guess.
- No `.clang-tidy`. Static analysis would catch the kind of small
  leaks the warning set doesn't.

---

## Systemic patterns

1. **Singletons via `Foo& CurrentFoo()`.** Everywhere. Five of them.
   They make threading impossible and refactoring expensive. Acceptable
   for the current single-document scope; will become a millstone the
   moment multi-document or multi-viewport lands.
2. **21-bit packed cell keys, redefined in four places.** Pick one
   home.
3. **Picking math reproduced in five Obj-C++ methods.** One helper,
   please.
4. **Tool gesture / shape preview / commit lifecycle living entirely
   on the `MTKView` subclass.** This is the file that's going to need
   surgery first.
5. **Comments-explain-why discipline.** Held remarkably well. Whoever
   has been reviewing comments, keep doing it.
6. **No tests on data structures, despite their criticality.** This is
   the single most-fixable thing on the list and the highest-leverage.
7. **Doc-version bump as the only invalidation primitive.** Cheap and
   effective. The cost is that *anything* that touches the document
   triggers a full reupload in the path tracer; for the editor's
   incremental upload this is mediated by the dirty-chunk set, but for
   PT it's wholesale. Document the contract.

---

## Grudging acknowledgments

- **Path tracer correctness work** (medium handling, VNDF GGX, MIS,
  Beer-Lambert with parametric distance against the clipped origin) is
  the right level of careful, with comments that explain the traps you
  fell into and climbed out of. That's a craftsman's notebook in the
  file.
- **`VoxelGrid::Set` neighbor-version bump on chunk boundaries.** Easy
  to forget; you didn't.
- **`RaycastRenderer` incremental upload with pool growth, padded
  bounds, palette fingerprint, and dirty-set drain.** This is what
  "responsive editing on big scenes" actually costs to implement, and
  you paid the bill.
- **Headless render path with deterministic seeds.** Most graphics
  projects skip this and regret it. You did the right thing.
- **`CLAUDE.md` itself.** It made my survey faster, even where it was
  stale.

---

## The triage list

Order by what hurts soonest if left alone.

**Now (next two days of work):**
1. Update `CLAUDE.md`'s "What the path tracer doesn't have yet"
   section. NEE and ACES are no longer absent. Tonemap-as-exposure and
   sun/sky are still gaps. This is a 5-minute fix and currently misleads
   the next reader.
2. Add `VoxelGrid` unit tests. Set/Get/Clear, neighbor-bump on
   boundary, chunk eviction on filled_count==0, bounds correctness on
   Set (and looseness contract on Set(0) explicitly asserted).
3. Add `EditHistory` unit tests. Same-cell coalescing, redo
   invalidation, kMaxOps cap, abandon vs commit semantics.

**Soon (next two weeks):**
4. Extract shape-tool enumeration + commit logic out of `VoxelView.mm`
   into `Shapes.{h,cpp}`. Take `Bresenham3D`, `ProjectInPlane`,
   `OffsetInPlane`, the line/circle/square/face enumerators, and the
   shape-preview state machine with you. `VoxelView.mm` should drop
   below 1,200 lines.
5. Consolidate the four `PackCellKey` definitions into one header.
   Delete the duplicates.
6. Single picking-ray helper. Five copies of the same NDC→world
   inverse-VP unproject is too many.
7. `VoxFile` round-trip test against `test/vox/teapot.vox` and the
   sample files. No assertion necessary beyond "load, save to /tmp,
   reload, compare grids and palettes."

**Eventually (next quarter, if scope grows):**
8. Wrap `CurrentTool / CurrentHistory / CurrentSelection /
   CurrentClipboard / CurrentRenderState` in a `Session` struct. No
   behavior change; gets you out of singleton-land before
   multi-document forces the issue.
9. Extract per-material scatter functions in the path-trace shader
   (`scatter_metal`, `scatter_glass`, `scatter_diffuse`) into named
   device functions. Keep the bounce loop as the integrator skeleton.
10. Pull the path-trace MSL out of the `NSString` literal into a
    `.metal` file and load via `MTLLibrary`. Once. As a planned piece
    of work, not bundled with a feature change.
11. CI: GitHub Actions, build + unit tests + a single headless render
    md5 check.

**Optional but cheap:**
12. `.clang-format` checked in. Match what's already there; freeze it.

---

## Closing assessment

For a one-developer Metal/AppKit/ImGui voxel editor with a real path
tracer, this codebase is in better shape than most projects of its size
that have shipped commercially. The disciplined comments, the careful
incremental renderer, the medium-aware path tracer, and the headless
render harness are all signs that the developer understands the
difference between "works" and "doesn't break six months from now."

The two real risks are: (1) `VoxelView.mm`'s steady accretion of
unrelated logic, which will eventually cost a refactor weekend, and
(2) the absence of unit tests for the data structures everything else
depends on, which means any structural change to `VoxelGrid` or
`EditHistory` is a leap of faith. Both are addressable in a week of
focused work, with no architectural rework required.

Survivable. Worth keeping. Fix the testing gap before you tell yourself
you don't need to.
