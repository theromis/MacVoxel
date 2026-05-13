# Splash mode

Replicates MagicaVoxel's "Stochastic Sampling Global Illumination = OFF"
aesthetic in our path tracer. Lives on the `splash-mode` branch (commit
`fc81d37`).

## What it does

A non-photorealistic rendering mode that produces MagicaVoxel's signature
look:

- **Smooth direct illumination** on surfaces that see emitters directly
  (e.g. floor in front of a glowing voxel cluster). Comes from area-light
  NEE.
- **Coherent shaped splashes** on surfaces lit only by indirect bounces
  (e.g. wall behind a cluster). Each accumulation sample projects the
  emissive cluster's silhouette onto the receiver through tile-correlated
  BSDF directions.

The result is a stylized render that reads as MagicaVoxel-ish rather than
strict physically-based.

## Reference material

We captured MagicaVoxel's path-tracer GLSL via `DYLD_INSERT_LIBRARIES`
interposition of `glShaderSource`. Lives at
`/Users/pstarr/dev/magicaVoxel-decompile/analysis/shaders/pathtracer/`.
Notable files:

- `pt_main.annotated.glsl` — the full fragment shader, with comments.
- `pt_bloom.glsl` — the stochastic bloom pass we ported.
- `FLAGS.md` — feature-flag reference (note: its claim that `OPT_AREA`
  alone is the SS-GI toggle is incomplete; see below).
- `FIREFLIES.md` — analysis of where the splash character comes from.

## How to use it

In the running app, **Light panel**:

- **Area-light NEE** (default on): explicit shadow rays toward emissive
  voxels. Produces the smooth direct illumination.
- **Splash mode** (default on): tile-correlated BSDF directions +
  tile-correlated NEE light selection + indirect-bounce proportional
  clamp. Produces the splash character and tames fireflies.

Both can be toggled independently. The Magica look is **both on**.

Sub-settings under "Splash mode":

- **Splash clamp** (0–32, default 8): hue-preserving proportional clamp
  applied to indirect emit contributions (NEE *and* BSDF-walk) at
  `bounce >= 1`. Magica's range is 4–16.
- **Splash jitter** (0–0.2, default 0): per-frame BRDF-direction
  perturbation. 0 = every pixel samples the same direction per sample
  (the splash "marches" across samples). Higher values widen the
  within-frame cluster-silhouette projection.
- **Splash scale** (1–64 px, default 16): correlation tile size. One
  noise sweep per `scale × 64` pixels.


### Headless renders

Same controls on the `render` CLI subcommand:

```sh
build/MacVoxel.app/Contents/MacOS/MacVoxel render \
  --input scene.vox --output out.png \
  --samples 256 --bounces 5 --seed 1 \
  --no-area-nee \             # disable NEE (BSDF-walk emit only)
  --sky-intensity 0 \         # kill ambient so emitters dominate
  --splash-jitter 0.05 \      # within-frame splash width
  --splash-tile-px 16 \       # correlation scale
  --bloom-intensity 0.6 \     # bloom mix (0 disables)
  --bloom-threshold 1.0 \
  --bloom-samples 48
```

## Path-tracer mechanism

Three pieces working together. All gated behind `splash_mode`; orthogonal
to `area_light_nee`.

### Tile-correlated BSDF directions

`src/PathTrace.metal` — `dir_sample()` routes the BRDF direction sample
through `jitter2(lobes[bounce], jitter_seed)` instead of two `rand1(rng)`
calls. `lobes[]` is a per-sample uniform array (one float2 per bounce,
shared by all pixels); `jitter_seed` is a per-pixel scalar bilinearly
sampled from a 64×64 white-noise texture.

With linear filtering the seed varies smoothly across pixels, but adjacent
pixels see nearly-identical seeds → nearly-identical BRDF directions →
their bounces land on neighbouring voxels of the same emissive cluster.
The cluster silhouette projects coherently onto the receiver as a shape
rather than scattering into single-pixel fireflies.

### Tile-correlated NEE selection

Same trick on the NEE side. Without it, per-pixel PCG picks different
emissive faces for each pixel and the NEE contributions firefly badly.
`pickrand1(u, rng, seed)` returns the mutated tile-correlated seed when
splash mode is on, else falls back to `rand1(rng)`. Used inside
`nee_sample_light` and `nee_sample_sun` for every random they consume
(light index, face axis, in-face position, RIS reservoir, sun cone).

Roughly mirrors Magica's frame-uniform area-light uniforms (`area_p`,
`area_n`, `area_L`): adjacent pixels evaluate the *same* emissive face
per sample, killing fireflies; the chosen face changes across samples,
so the integration still converges.

### Per-bounce proportional clamp

`nee_clamped(u, b, contrib)` wraps every NEE accumulation site and the
BSDF→emit MIS arrival branch. Hue-preserving clamp to
`indirect_clamp_L` when `b >= 1` and splash mode is on.

Why `b >= 1` specifically: at `b == 0` (the camera ray's first surface
hit) the NEE shadow ray carries the smooth-halo direct contribution and
should pass through unclamped. From the second surface interaction
onward, indirect-path variance is what spikes into fireflies, and the
clamp tames it. This matches Magica's `bounce > 1` clamp in
`SAMPLE_LIGHT_DEF` / `EVAL_LIGHT_DEF` (their bounce counter increments
inside the material function, so their `bounce == 1` is our `b == 0`).

### Convergence: per-sample jitter phase

The tile-correlated jitter chain is initialised once per pixel from the
noise texture. That value is **constant across accumulation samples** —
so without intervention, every sample's NEE produces the same sequence
of light picks and contributes the same value. Variance never reduces.

Fix: `PathUniforms::jitter_phase` is a per-accumulation-sample uniform
in `[0, 1)`. The shader initialises the per-pixel seed as
`fract(tex_rand[pix] + u.jitter_phase)`, so the chain *shifts* across
samples. Per-pixel within a sample still tile-correlates (all
neighbours share `jitter_phase`); per-pixel across samples decorrelates
(different `jitter_phase`).

This is the textbook Monte Carlo trap that's easy to miss when adding
spatial correlation — without temporal decorrelation, you're not
sampling an integral, you're computing one biased point estimate
infinitely.

## How this maps to MagicaVoxel

FIREFLIES.md's analyst empirically confirmed (via shim-capture of a
multi-emissive scene) that the SS-GI toggle gates the `OPT_AREA`
`#define` in MagicaVoxel's path-tracer shader. The mapping is:

|                     | `splash_mode` | `area_light_nee` |
|---------------------|---------------|------------------|
| MV "SS-GI ON"       | on            | on               |
| MV "SS-GI OFF"      | on            | off              |
| Reference MC (ours) | off           | on               |

The two MV modes are both stylized — MV always runs tile-correlated
jitter and indirect-clamp on top; only NEE for area lights differs.
Sun NEE is independent of both flags (matches MV's `OPT_SUN`).

Our renderer's **default is `splash_mode + area_light_nee` both on**,
which is the smoother of the two and reads as "Magica-like" to most
people — but it's actually closer to MV with SS-GI **ON** than OFF.
Flip area-light NEE off to get MV's SS-GI **OFF** look (visible
cluster-silhouette splashes, no smooth halo from explicit NEE).

### Where the previous misreading came from

An earlier draft of this document claimed MV's "SS-GI OFF" was a
hybrid mode (NEE stays on, only indirect becomes splashy), reasoning
from the observation that "our `splash + no area NEE` setup is
noticeably noisier than MV's SS-GI OFF at equivalent sample counts."
That reasoning was wrong on two counts:

1. The shim-captured shader is definitive — with SS-GI off,
   `OPT_AREA` is not compiled into MV's shader, so area-light NEE
   literally cannot run there.
2. The noisier-than-MV observation is real, but the cause is not
   "MV runs hidden NEE" — it's that our renderer was missing the
   temporal-EMA blend MV does in `pt_post.glsl`
   (`mix(tex_last, dst, weight)`) which substantially smooths visible
   per-frame variance during accumulation. That's now implemented
   (see "Temporal EMA accumulator" below).

### Bloom

Magica's bloom pass exists and adds glow on bright pixels, but the
smooth halo on diffuse surfaces in MV survives with bloom disabled.
The halo's real source in MV is: high-probability BSDF-walk discovery
of nearby emitters + the indirect clamp keeping each contribution
bounded + the temporal-EMA blend averaging many samples. Bloom is
post-process polish on top.

## Files changed (commit fc81d37)

```
src/CliRender.mm                       (+50)  CLI flags
src/MetalScene.mm                      (+6)   export with bloom
src/PathTrace.metal                    (+250) bloom_fragment, splash plumbing
src/PathTraceRenderer.h                (+1)   exportPNGToURL signature
src/PathTraceRenderer.mm               (+230) bloom pipeline+texture, plumbing
src/RenderState.h                      (+33)  new settings
src/swift/EditorContextBridge.h        (+10)  bridge properties
src/swift/EditorContextBridge.mm       (+30)  getter/setters
src/swift/EditorState.swift            (+35)  Swift proxies
src/swift/panels/LightPanel.swift      (+50)  UI
```

## What's not perfect

- **Splash mode + NEE noise floor**: at low samples the hybrid is
  noisier than Magica at equivalent sample counts. Likely candidates
  for further work: the bloom radius/threshold defaults aren't tuned
  per-scene; the per-bounce clamp may be too aggressive on
  high-frequency lighting; we're not yet doing the temporal-EMA
  blending Magica's `pt_post.glsl` does (`mix(tex_last, dst, weight)`).

- **Bloom is computed per-frame even when accumulator is converged**:
  could be skipped once samples ≫ bloom_num_samples and the result is
  already stable.

- **Splash scale slider has no visible effect when Splash jitter = 0**:
  documented in the tooltip but easy to miss.
