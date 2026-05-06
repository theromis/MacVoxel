# Path Tracer Review

Reviewed code:

- `src/PathTraceRenderer.mm`
- `src/PathTraceRenderer.h`
- `src/RaycastRenderer.mm`
- `src/VoxelGrid.{h,cpp}`
- `src/RenderState.h`
- `src/ui/RenderPanel.cpp`

This is a static review, not a profiler pass. Performance recommendations below are ranked by likely impact from the code shape; they should be validated with GPU counters or at least fixed-seed headless render timing before doing invasive work.

## Executive Summary

The path tracer is architecturally sound for a compact editor renderer. The major choices are defensible: it reuses the sparse voxel chunk layout, keeps palette colors in linear space on the GPU, uses progressive accumulation, provides deterministic headless rendering, uses empty-chunk skipping, has Russian roulette, and now includes next-event estimation plus MIS. Those are the right broad strokes for a physically motivated voxel path tracer.

The weak point is that the implementation has outgrown a single inline shader string inside `PathTraceRenderer.mm`. Traversal, BSDF sampling, MIS, glass medium state, lighting, display tonemapping, CPU resource upload, GUI render flow, and headless flow are all coupled in one file. That does not make the renderer wrong, but it does raise the cost and risk of future physical-accuracy work.

The most promising performance work is not a new BSDF trick. It is reducing traversal and shadow-ray cost:

1. Build a better light-sampling representation from exposed emissive faces, ideally power-weighted.
2. Add a second level of in-chunk empty-space skipping or occupancy masks.
3. Consider moving the accumulation pass from a fragment render pass with additive blending to a compute kernel once you want batching, tiling, adaptive sampling, or multiple samples per dispatch.
4. Stop doing whole-document GPU resource rebuilds for palette/material-only edits.

## What Looks Strong

### Data Layout Matches The Problem

The GPU scene representation mirrors the editor's sparse `16^3` chunk grid: a dense coarse grid maps chunk coordinates to a compact chunk pool, and DDA skips fully empty chunks. That is a sensible baseline for voxel path tracing because it avoids a dense world-size allocation while keeping cell lookup cheap and predictable.

The path tracer also shares the same coarse-grid/chunk-pool idea as the raycast renderer. That keeps interactive and path-traced rendering aligned enough that picking/rendering mismatches are less likely.

### The Integrator Has The Right Modern Features

The shader is not just brute-force cosine bouncing. It has:

- next-event estimation against emissive voxels
- MIS between NEE and BSDF-sampled emitter hits
- GGX VNDF sampling for rough metal/glass reflection
- Beer-Lambert medium attenuation for connected same-material glass
- Russian roulette after a couple of bounces
- deterministic frame seeds for headless comparison

That is a solid feature set for the product's current scope.

### Accumulation Semantics Are Mostly Clean

Accumulation resets on camera, document, resolution, and glass-mode changes. Fixed-seed headless rendering gives you a practical regression tool. The display pass divides the HDR accumulation texture by sample count and handles aspect-preserving presentation, which keeps interactive iteration and export using the same accumulated data.

## Architectural Concerns

### 1. The Inline Shader Is Now Too Large

`PathTraceRenderer.mm` embeds the full MSL source starting at `kShaderSource`, and the path tracer fragment alone contains traversal, light sampling, BSDF evaluation, medium handling, Russian roulette, and display code. This was reasonable early on, but it is now a maintenance risk.

Concrete issues:

- CPU and MSL structs are manually duplicated.
- The shader cannot be tested, linted, or syntax-highlighted normally.
- Small physical changes require editing a long string with no module boundaries.
- Traversal changes are duplicated mentally against `RaycastRenderer.mm`.
- Comments are carrying too much invariant load because the code cannot be decomposed.

Recommendation: move shader code into real `.metal` sources or at least generated included strings. Split it conceptually into:

- `VoxelTraversal.metal`
- `Sampling.metal`
- `Bsdf.metal`
- `Lights.metal`
- `PathTrace.metal`
- `Display.metal`

Keep the Obj-C++ side as pipeline/resource orchestration. This does not need to be a large refactor all at once; start by extracting the shader string unchanged into a `.metal` file loaded through the default library or build-system-embedded source.

### 2. Shared GPU Layout Needs A Single Owner

`PathUniforms`, `GpuMaterial`, `GpuLight`, and `Chunk` are duplicated between C++/Obj-C++ and MSL. There are CPU-side `static_assert`s for struct size, but they do not prove the MSL side still matches.

Recommendation: introduce a small shared GPU schema header or generator. If true shared C++/MSL headers are awkward because of Objective-C++/Metal syntax, at least centralize the CPU declarations and add a tiny shader-side layout validation convention where feasible.

Also consider packing palette color and material into one 256-entry GPU table. Every surface hit currently loads both `palette[h.cell_val]` and `materials[h.cell_val]`; the table is tiny, but a single material/color record would simplify binding and avoid accidental drift between parallel buffers.

### 3. Traversal Is Duplicated With The Raycast Renderer

The raycast renderer and path tracer both implement coarse-grid DDA with empty-chunk skipping, but the path tracer has additional medium-exit semantics. Some duplication is unavoidable because the shader requirements differ, but the shared math is subtle enough that drift is a real risk.

Recommendation: extract a common traversal module with two entry points:

- ordinary first-hit traversal for raycast/shadow rays
- medium-aware traversal for glass

The goal is not abstraction for its own sake. The goal is to avoid fixing numeric edge cases in one renderer while leaving the other with stale boundary behavior.

### 4. Global Render State Leaks Into Renderer Internals

`PathTraceRenderer` takes explicit `maxBounces` for headless accumulation, but still reads `CurrentRenderState().glass_mode` while encoding uniforms and `CurrentRenderState().aces_tonemap` during export. GUI and headless modes are therefore not fully isolated.

Recommendation: pass a small immutable render-settings struct into render/export paths. The global `RenderState` can still be the UI source of truth, but `PathTraceRenderer` should not need to reach back into it during lower-level encoding.

### 5. Empty Documents Return Before Display/Clear

When `_coarseBuffer` or `_poolBuffer` is nil, `renderInView` returns before the display pass, even though the comment says to let display clear to background. If a path-traced render had been visible and the document becomes empty, this risks leaving stale drawable contents or failing to update the visible output consistently.

Recommendation: make the empty-scene path explicit. Either clear/draw sky/ground through the display pass, or encode a simple clear pass and update `sample_count`.

## Performance Review

### 1. Shadow Rays Are Probably The Dominant Cost In Lit Scenes

Every non-emissive surface bounce does a NEE sample, and every NEE sample traces a shadow DDA through the same voxel structure. That roughly doubles traversal work for diffuse/metal/glass-reflect bounces before counting additional BSDF continuation rays.

This is the right trade for physical convergence around small lights, but it means light sampling quality matters a lot. The current light list is one entry per emissive voxel, sampled uniformly, then one of three faces is sampled. That is simple and likely unbiased for visible cube faces, but it wastes samples on:

- low-power emitters when high-power emitters dominate
- buried/internal emissive voxels or faces that immediately fail visibility
- large emissive regions represented as many independent voxels with no area hierarchy

Recommendations:

- Build the light list from exposed emissive faces, not emissive voxels.
- Store face normal, corner/origin, area, and emitted radiance.
- Sample faces power-weighted by `luminance(Le) * area`.
- For adjacent emissive voxels with same material, consider coalescing coplanar exposed faces into rectangles later.

Expected impact: lower variance and fewer wasted shadow traversals. This improves both quality per sample and time-to-clean-image without compromising physical accuracy.

### 2. In-Chunk Empty Space Is Not Skipped

The two-level grid skips empty chunks, but once a chunk is non-empty, traversal falls back to cell-by-cell stepping. A chunk with one voxel and 4095 empty cells is treated as occupied for every ray crossing it.

For sparse voxel art, that can be a major cost because a visually sparse model can still create many mostly-empty chunks. This cost is multiplied by bounces and shadow rays.

Recommendations, from least to most invasive:

- Add a `uint64_t` or small array occupancy mask per chunk for `4^3` bricks and skip empty bricks.
- Store per-axis or per-brick occupancy summaries to jump within chunks.
- Build a small clipmap/mipmap occupancy hierarchy over the coarse grid for larger scenes.

The current empty-chunk skip should stay; the missing piece is a level between `16^3 chunk is empty` and `step every voxel cell`.

### 3. Fragment-Pipeline Accumulation Is Simple But Limits Future Performance Work

The accumulation pass is a fullscreen triangle fragment shader writing to an `RGBA32Float` render target with additive blending. That is a good minimal implementation, but it constrains next steps:

- one sample per render pass in GUI mode
- one command buffer per sample in headless mode
- no natural place for tile scheduling or adaptive sampling
- no easy persistent per-pixel RNG/sample state
- blend hardware writes an unused alpha channel too

Recommendation: keep the current path until profiling shows dispatch overhead or bandwidth is material. When you need more control, move accumulation to compute:

- one thread per pixel or small tile
- loop `N` samples per dispatch for headless/export
- write accumulated RGB plus sample count explicitly
- support adaptive sampling or progressive tile refinement later

This is not urgent for the current editor loop, but it is the right architectural direction for serious offline-quality renders.

### 4. Headless Rendering Submits One Command Buffer Per Sample

`renderHeadlessSamples` creates and commits a command buffer for every sample, then waits only for the last one. For hundreds or thousands of samples this can produce unnecessary CPU/driver overhead and queue pressure.

Recommendations:

- Batch multiple samples per command buffer, for example 16-64 accumulation passes per command buffer.
- If/when moving to compute, run multiple samples inside one kernel dispatch.
- Add timing output around GPU completion so headless renders can report samples/sec.

This is a low-risk improvement even before a compute migration.

### 5. Whole-Document Resource Rebuilds Are Conservative But Coarse

On any `doc->version` change, the path tracer rebuilds the coarse grid, chunk pool, palette buffer, material buffer, and light buffer. That is acceptable when entering render mode after editing, but it is inefficient for palette/material edits because most of the voxel pool is unchanged.

Recommendations:

- Track palette/material revision separately from grid revision.
- Re-upload palette/material buffers independently.
- Rebuild the light list when emissive material/color/emission changes, or when voxels using emissive indices change.
- Rebuild chunk/coarse buffers only when grid topology/cells change.

This mostly improves iteration latency when tuning materials and lights.

### 6. Use Private GPU Buffers For Static Scene Data

Scene buffers are created with `MTLResourceStorageModeShared`. That is convenient and fine for small scenes, but static path-trace data is read heavily by the GPU and not mutated by the CPU after upload.

Recommendation: benchmark private-storage buffers populated via blit for `_coarseBuffer`, `_poolBuffer`, and `_lightBuffer`. On Apple Silicon shared memory is not automatically bad, so this should be measured, but private buffers may still help cache residency and access flags.

### 7. RNG Quality Is Adequate But Not Variance-Optimized

The shader uses a PCG-style hash seeded by pixel and frame. That is acceptable and cheap, but not optimized for convergence. Purely random per-pixel sampling leaves visible noise patterns longer than blue-noise or low-discrepancy approaches.

Recommendations:

- Try a precomputed blue-noise texture for pixel/sample dimensions.
- Consider Cranley-Patterson-rotated low-discrepancy sequences for AA/light/BSDF dimensions.
- Keep fixed-seed determinism for regression renders.

This is a quality-per-sample improvement, not a raw milliseconds-per-sample improvement.

### 8. Micro-Optimizations To Consider Only After Profiling

These are plausible but should not be first-line work:

- Replace repeated `pow(x, 5.0)` Schlick calls with explicit multiply chains.
- Specialize roughness-zero glass/metal paths to avoid GGX math for mirror-like materials.
- Precompute material constants such as `r0`, clamped roughness, effective type, and linear albedo into the GPU material table.
- Avoid recomputing inverse view-projection per sample when camera/size are unchanged.
- Use function constants or separate pipelines for common feature modes if branch divergence shows up in counters.

## Physical Accuracy Notes

The renderer is physically motivated, but some current choices are artistic/product choices rather than strict physical transport:

- The virtual infinite ground plane is useful for legibility, but it is scene lighting not represented in the voxel document.
- The sky is a constant color, not an environment map or sun/sky model.
- Absorption mode caps "clear" glass toward `0.8`, which intentionally preserves ghost attenuation but is not physically clear glass.
- Metal material behavior is a probabilistic split between diffuse and specular based on `metallic`, rather than a full layered/energy-conserving material model.

Those are not necessarily problems. They should stay explicit because future work may otherwise optimize or "correct" them in ways that change the product's intended look.

## Suggested Priority Order

1. Extract the shader into real `.metal` source while preserving behavior.
2. Add render timing for headless samples and a small benchmark scene set.
3. Change the light buffer from emissive voxels to exposed emissive faces, then add power-weighted sampling.
4. Batch headless command buffers.
5. Add in-chunk occupancy skipping.
6. Split document resource rebuilds by grid vs palette/material/light changes.
7. Revisit compute-based accumulation when batching/adaptive sampling/tiling becomes important.

## Bottom Line

The current path tracer is a credible implementation, not a throwaway prototype. Its biggest risk is maintainability, not a fundamentally bad rendering architecture. The biggest performance opportunity is to spend fewer rays on unproductive traversal: better light sampling, fewer shadow-ray misses, and more empty-space skipping inside non-empty chunks.
