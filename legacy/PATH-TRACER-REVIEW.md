# Path Tracer Review

Reviewed primarily: `src/PathTrace.metal`

Supporting context checked: `src/PathTraceRenderer.mm`, `src/RenderState.h`, and `src/VoxelGrid.h`.

This is a static code review, not a GPU profiler pass. I focused on places where the renderer appears to do avoidable work per sample, plus a few correctness or consistency issues that can either waste samples or produce harder-to-converge output. Recommendations are biased toward preserving render quality.

## Executive Summary

The renderer is not doing naive brute-force path tracing. It already has several quality-preserving variance controls: next-event estimation, MIS, power-weighted light selection, RIS, empty-chunk skipping, Russian roulette, correlated sampling, GGX VNDF sampling, and connected-medium handling for same-material glass. Those are good decisions.

The main cost center is traversal. Every camera/path ray and every direct-light or sun shadow ray runs `dda_traverse`, and the current traversal repeats substantial chunk bookkeeping for every cell inside occupied chunks. The next largest cost centers are direct-light sampling work before each shadow ray, repeated expensive sky integration, and duplicated BSDF/NEE code paths that make it easy to miss optimizations or consistency fixes.

Highest-value improvements:

1. Cache chunk state inside `dda_traverse` so occupied chunks do not reload/recompute coarse-grid state for every cell.
2. Add in-chunk empty-space skipping, such as 4x4x4 brick occupancy masks.
3. Change emissive sampling from "emissive voxel, then one of three faces" to an exposed-emissive-face light list.
4. Precompute or cache atmospheric sky into an environment texture instead of running the Nishita integral on every sky miss.
5. Add cheap call-site guards for disabled light/sun paths and consolidate duplicated NEE code.

## Findings

### 1. DDA Repeats Coarse-Grid Work For Every Cell In Occupied Chunks

Location: `src/PathTrace.metal:538-637`

Inside the DDA loop, every step recomputes:

- `chunk_c = cell >> kChunkBits`
- `cgc = chunk_c - u.coarse_min`
- bounds checks against `u.coarse_dim`
- flattened `coarse_idx`
- `pool_idx = coarse_grid[coarse_idx]`

That is necessary when the ray crosses into a new chunk, but wasteful for the common case where the next cell is still inside the same non-empty 16x16x16 chunk. In a dense or partially occupied chunk, a ray can take many voxel steps while `pool_idx` and chunk bounds stay unchanged.

Recommendation: restructure traversal around a cached current chunk:

- Compute chunk coord and `pool_idx` when entering a chunk.
- If `pool_idx == 0`, use the existing empty-chunk skip.
- If `pool_idx != 0`, step local cells until crossing a chunk boundary, loading only `chunk_pool[pool_idx - 1].cells[local_idx]` per cell.
- Recompute coarse-grid state only after crossing a chunk boundary.

This should reduce integer ALU and coarse-grid memory reads without changing the traced paths.

### 2. No In-Chunk Empty-Space Skipping

Location: `src/PathTrace.metal:632-682`, CPU upload at `src/PathTraceRenderer.mm:403-425`

The renderer skips fully empty chunks, but once a chunk has any voxel, it steps cell by cell through the entire chunk. A chunk with one filled voxel and 4095 empty cells is as expensive to cross as a mostly full chunk.

Voxel art scenes often contain many sparse boundary chunks. Shadow rays multiply this cost because every NEE query also traverses the same structure.

Recommendation: add a compact occupancy hierarchy per chunk:

- Low-risk first step: store a 4x4x4 brick occupancy mask per chunk. A ray entering an empty brick can skip to the next brick boundary.
- Better later: store axis-aware masks or a tiny per-chunk mip hierarchy.

This preserves exact voxel hits while avoiding cell-by-cell walks through known-empty regions.

### 3. `kMaxSteps = 4096` Is Both A Safety Valve And A Possible Miss Bug

Location: `src/PathTrace.metal:322`, loop at `src/PathTrace.metal:538`

`dda_traverse` returns a miss when the loop reaches 4096 iterations. Because one iteration can mean either one voxel step in an occupied chunk or one empty-chunk skip, this cap can terminate valid long rays before they leave the sparse AABB.

For normal compact models this may never trigger. For large imported scene graphs, widely separated chunks, or long diagonal shadow rays, it can produce missing occlusion or missing hits. It also makes performance behavior scene-scale dependent in a hidden way.

Recommendation: prefer termination based on `t_exit` or explicit chunk/AABB exit rather than a fixed iteration cap. Keep a very high defensive cap only as an assert-style fallback if Metal needs one.

### 4. Direct-Light Sampling Still Wastes Work On Hidden Or Irrelevant Faces

Location: `src/PathTrace.metal:808-950`, light build at `src/PathTraceRenderer.mm:478-572`

The light list is one entry per emissive voxel. Each NEE candidate then chooses one of three faces based on the receiver position.

This is simple, but it still spends candidate work on emissive voxels or faces that are not actually exposed to air. Interior emissive cells in a solid light cluster can remain in the light list and generate candidates that can never be directly visible. Even for exposed lights, the shader has to reconstruct face geometry every candidate.

Recommendation: build the light buffer from exposed emissive faces:

- Store face origin, normal, emitted radiance, area, and sampling probability.
- Weight by `luminance(Le) * area`.
- Later, merge adjacent coplanar faces with the same material into rectangles.

This reduces wasted RIS candidates and makes each shadow ray more likely to test a useful light sample. It improves quality per sample without biasing the estimator.

### 5. RIS Candidate Count Multiplies Expensive Per-Hit Work

Location: `src/PathTrace.metal:841-932`; default `nee_ris_count = 8` at `src/RenderState.h:111-119`

The RIS path fires only one shadow ray, which is good, but each shading point still does `M` candidates. Each candidate may do random picks, CDF binary search, face construction, `sqrt`, direction normalization, cosine checks, source-pdf math, and reservoir update. With the default `M = 8`, this is non-trivial at every non-delta bounce.

This can absolutely be worth it when it prevents noisy shadow rays. The inefficiency is that the current source representation forces the shader to rediscover face geometry and candidate weights every time.

Recommendations:

- Exposed-face light records will remove much of the per-candidate reconstruction.
- Consider alias-table sampling for power-weighted lights if light counts become large. The current binary search is `O(log light_count)` per candidate.
- Consider adapting `M`: first bounce and high-throughput paths benefit most; late bounces after Russian roulette may not need 8 candidates.

### 6. Area-Light And Sun NEE Are Called Even When They Are Disabled

Locations:

- Light NEE guard inside callee: `src/PathTrace.metal:826`
- Sun NEE guard inside callee: `src/PathTrace.metal:981-983`
- Repeated call sites: `src/PathTrace.metal:1333-1339`, `1460-1466`, `1475-1481`, `1525-1531`, `1550-1558`, `1586-1592`, `1605-1613`

`nee_sample_light` and `nee_sample_sun` return quickly when disabled, but most call sites still construct and pass the full argument list on every relevant bounce. The functions also zero-initialize an `NEELight` before the feature checks.

The compiler may inline and simplify some of this, but `u.light_count` and `u.sun_radiance` are runtime uniforms, so the shader still carries the branches.

Recommendation: add explicit call-site guards:

- `if (u.light_count != 0u) { ... nee_sample_light ... }`
- `if (sun_enabled) { ... nee_sample_sun ... }`

Compute `sun_enabled` once near the top of `pt_fragment` or encode it as a uniform. This is small, but it removes dead work in common scenes with no emissives or no sun.

### 7. Atmospheric Sky Is Very Expensive Per Sky Miss

Locations: `src/PathTrace.metal:374-458`, sky miss at `src/PathTrace.metal:1371-1375`, horizon blend at `src/PathTrace.metal:1317-1324`

`nishita_sky_radiance` performs 32 view samples, and each view sample calls `atmosphere_transmittance`, which performs 8 more samples. That is roughly 256 transmittance sample evaluations per sky query, with repeated `sqrt`, `exp`, and vector math.

When atmospheric sky is enabled, this runs for escaped primary rays, escaped secondary rays, and sometimes for the primary ground-horizon fade. It is physically nicer than a constant sky, but it is a lot of repeated deterministic work.

Recommendation: precompute a sky environment texture whenever sun/atmosphere settings change:

- 2D lat-long or octahedral map in grid direction space.
- Same Nishita integral, just evaluated once per texel instead of per path escape.
- Sample the map in the path tracer for sky misses and horizon fade.

This keeps the same sky model while moving work out of the per-sample hot path. Use sufficient resolution and filtering so this is a cache, not a quality downgrade.

### 8. Direct Sun NEE Rebuilds A Basis Every Shading Point

Location: `src/PathTrace.metal:985-1001`

`nee_sample_sun` constructs a TBN around `u.sun_dir_grid` for every sun sample. The sun direction is uniform for the whole pass, so the basis can be computed CPU-side and uploaded, or computed once per fragment and reused across bounces.

Recommendation: add `sun_tangent_grid` and `sun_bitangent_grid` to `PathUniforms`, or compute them once near the top of `pt_fragment` and pass into a lighter sun sampler. This saves a normalize/cross sequence per sun-NEE call.

### 9. BSDF Basis Construction Is Repeated And Uses Full Normalization

Locations:

- `cosine_hemi`: `src/PathTrace.metal:244-248`
- `ggx_sample_vndf`: `src/PathTrace.metal:282-286`

Surface normals are axis-aligned voxel face normals. For six possible normals, the tangent frame can be selected from constants rather than built with `cross` and `normalize` for every diffuse, metal, and glass sample.

Recommendation: replace generic basis construction for voxel normals with a small axis-normal helper returning fixed `t1/t2`. Keep the generic path only if future non-axis-aligned geometry needs it.

This is a pure ALU reduction and should not affect sampling quality.

### 10. Several Expensive `pow(x, 5.0)` Calls Are Schlick Powers

Locations:

- `nee_ggx_mis`: `src/PathTrace.metal:1067`
- glass entry Fresnel: `src/PathTrace.metal:1516`
- glass exit Fresnel: `src/PathTrace.metal:1256`

Schlick Fresnel uses `(1 - cos)^5`. Calling generic `pow` is usually more expensive than a multiply chain.

Recommendation: introduce:

```metal
inline float pow5(float x) {
    float x2 = x * x;
    return x2 * x2 * x;
}
```

Then use `pow5(saturate(...))`. Same math, less work.

### 11. Material Constants Are Recomputed At Every Hit

Locations: material load at `src/PathTrace.metal:1381-1383`, repeated clamps/Fresnel setup at `1457-1458`, `1509-1518`, `1238-1256`

The shader repeatedly computes:

- clamped roughness
- clamped metallic/transparency
- dielectric `r0`
- linear albedo from a separate palette table
- material type conversion from float to uint

The material table has only 256 entries and is rebuilt CPU-side already. It can carry precomputed shader-ready fields.

Recommendations:

- Store material type as `uint`, not `float`, if layout permits.
- Combine palette and material into one GPU table: `albedo`, `emission`, `roughness`, `metallic`, `transparency`, `ior`, `r0`, flags.
- Precompute clamped values CPU-side.

This reduces per-hit ALU and one constant-buffer lookup.

### 12. Display Tonemapping Is Duplicated

Locations:

- `ema_compose_fragment`: `src/PathTrace.metal:1687-1695`
- `display_fragment_direct`: `src/PathTrace.metal:1749-1757`

The ACES/gamma conversion appears twice. This is not a major runtime cost because only one display path is used at a time, but it is a maintenance redundancy. A future change to tonemapping can easily update one path and miss the other.

Recommendation: extract `tonemap_to_srgb(float3 c, uint aces_tonemap)`.

### 13. NEE Contribution Logic Is Repeated Across Material Branches

Locations: diffuse/metal/glass/ground NEE blocks throughout `src/PathTrace.metal:1332-1340` and `1459-1614`

Almost every material branch repeats the same shape:

- sample area light
- add clamped diffuse or GGX MIS contribution
- sample sun
- add clamped diffuse or GGX MIS contribution

This creates code size, branch pressure, and consistency risk. There is already one visible inconsistency: the glass probabilistic diffuse fallback adds NEE without `nee_clamped` at `src/PathTrace.metal:1588-1592`, while the ordinary diffuse path clamps indirect NEE at `src/PathTrace.metal:1608-1613`.

Recommendation: consolidate into helpers like:

- `add_diffuse_nee(...)`
- `add_ggx_nee(...)`

They can contain the area/sun enabled guards and the clamp policy once.

### 14. DDA Shadow Rays For Area Lights Do Not Use A Max Distance

Location: shadow ray in `nee_sample_light` at `src/PathTrace.metal:936-940`

For a sampled finite light point, the visibility query only needs to know whether anything blocks the segment from `x` to the sampled face. The current call traces until the first hit or until it leaves the whole sparse AABB, then checks whether the first hit cell is the chosen light.

Usually the chosen light is the first hit when visible, so this is fine. But if numerical issues step past the chosen face, the traversal may continue farther than the sampled-light distance. A segment-limited DDA would also make the intended visibility test explicit.

Recommendation: add an optional `t_max_distance` to the shadow traversal path. Stop once the current DDA distance exceeds the sampled point distance plus epsilon. This can reduce worst-case work and makes the shadow query more robust.

### 15. Primary-Ray Setup Uses Matrix Unprojection Per Pixel

Location: `src/PathTrace.metal:1120-1135`

Every fragment multiplies two clip-space points by `inv_vp`, divides by `w`, subtracts, normalizes, and converts world to grid. This is standard and correct, but for a fullscreen pinhole camera it is more work than necessary.

Recommendation: upload grid-space camera basis and frustum corner/ray differentials. Generate the ray direction from interpolated basis vectors and normalize once. The DOF code already needs grid-space camera basis, so this would align primary-ray setup with the rest of the shader.

This is lower priority than traversal because it happens once per sample, not per bounce/shadow ray.

### 16. The Jitter Noise Comment Disagrees With The Actual Sampler

Locations:

- CPU comment says nearest: `src/PathTraceRenderer.mm:155-158`
- Shader uses linear filtering: `src/PathTrace.metal:1106-1111`

The shader comment and code agree that the noise texture is bilinear-filtered. The CPU-side comment says nearest filtering and 16x16 tiles. This is not a runtime bottleneck, but it is a maintenance blunder in a sampling-sensitive area.

Recommendation: update the stale CPU comment so future sampling changes are not made from the wrong mental model.

### 17. Comments For EMA Weight Are Stale In The Uniform Definitions

Locations:

- `src/PathTrace.metal:86-90`
- `src/PathTraceRenderer.mm:104-108`
- actual behavior: `src/PathTraceRenderer.mm:820-845`

The uniform comments still describe `max(1/(sample_count+1), ema_floor)`, but the actual code uses `ema_floor` directly after the first valid history frame. This is not a path-tracing hot path, but it is another stale-comment issue in renderer behavior.

Recommendation: update the comments or rename the field to match the current semantics.

## Suggested Priority Order

1. Optimize `dda_traverse` chunk-state caching.
2. Add per-chunk brick occupancy skipping.
3. Build an exposed-face light list and simplify NEE candidate generation.
4. Add call-site guards and helper functions for area/sun NEE.
5. Precompute atmospheric sky into an environment texture.
6. Replace axis-normal basis construction and Schlick `pow` calls with cheaper exact equivalents.
7. Precompute material constants and consider merging palette/material GPU tables.
8. Add segment-limited shadow traversal for finite light samples.
9. Clean up stale comments and duplicated tonemap code.

## Validation Plan

Before changing behavior, add a small fixed-seed benchmark set:

- empty sky / ground scene
- dense cube
- sparse imported model
- emissive cluster with many hidden/internal emitters
- glass-heavy scene
- atmospheric sky enabled

Measure GPU time per accumulated sample and keep fixed-seed image comparisons for changes that should be mathematically identical. Traversal caching, fixed tangent frames, `pow5`, material precomputation, and call-site guards should be visually identical. Light-list changes and sky caching should be compared against high-sample references because they change sampling strategy or approximated lookup resolution.
