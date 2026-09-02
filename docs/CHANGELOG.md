# Changelog

## 1.5.8 — 2026-09-01

*123 commits.* Numeric and reader conformance. Every change in this release
landed with a test that was red before it, and the cycle was driven by mutation
testing: a claim that no mutation could redden was treated as a defect in the
claim.

### API

**New libraries.** `(gfx raster)` — a CPU rasterizer, 103 procedures covering
cameras (`make-rcam`, `rcam-project!`, `rcam-ray!`), frames, masks, images,
meshes, and the entry points `render-frame!`, `render-mask!`,
`render-mask-add!`, `render-textured!`, `frame-diff`, `mask-iou`.
`(gfx image)` — `png-decode!`, `png-encode!`, `png-info`, `tga-decode!`,
`tga-info`, `inflate!`, `zlib-inflate!`, `crc32`, `adler32`.
`(gfx glb)` — `glb-write!`, `glb-offset`, `glb-stride`.
`(gfx retarget)` — `retarget-clip!`, `retarget-write-glb!`, `retarget-report`,
`retarget-glb-node-names`, `retarget-normalize-name`.
`(web fs)` — `fs-slurp!`, `fs-spit!`, `fs-slurp-string`, `fs-spit-string!`,
`fs-exists?`, `fs-size`. `(web args)` — `args-count`, `args-ref`, `args-list`.
`(web utf8)` — `utf8-well-formed?`, moved here so both codecs ask one predicate.

**Added to existing libraries.** `(gfx gltf)` gains 22 node and skin accessors
(`gltf-nodes`, `gltf-node-translation`/`-rotation`/`-scale` with setters,
`gltf-node-parent`, `gltf-pose-at!`, `gltf-skins`, `gltf-skin-positions!`,
`gltf-skin-normals!`, `gltf-skin-program3!`, `gltf-animation-duration`).
`(gfx mat)` gains inverse trigonometry (`flasin`, `flacos`, `flatan`,
`flatan2`) and the quaternion algebra (`q-mul`, `q-conj`, `q-neg`, `q-dot`,
`q-normalize`, `q-slerp`). `(gfx gl)` gains `cmd-read-pixels!` and
`cmd-draw-elements-instanced32!`; `(gfx fx)` gains `fx-read-target!`,
`fx-mark`, `fx-release!`, `fx-program-blocks`; `(gfx glsl)` gains `glsl-check`,
`glsl-uniform-blocks`, `fl-literal->string`; `(gfx wgsl)` gains `wgsl-check`;
`(web json)` gains `json-array?` and `json-array->list`; `(web js)` gains
`js-callback-error!`.

**Added to the prelude**, as top-level bindings: `sin`, `cos`, `tan`, and the
R6RS division operators `div`, `mod`, `div0`, `mod0`.

**New runtime modules**, shipped in the package and importable from a page.
`rt/sexpr.mjs` — a dependency-free s-expression codec, so a page running the
**JS fallback** speaks the same wire as the Wasm build: `read`, `write`,
`toJSON`, `fromJSON`, `rpc`, `rpcJSON`, the `Sym` / `Ratio` / `Vec` /
`DottedList` value types, `base64Encode` / `base64Decode`, and the `MAX_TOKEN`
/ `MAX_SPINE` / `MAX_DEPTH` limits it enforces. `rt/verify.mjs` and
`rt/pack.mjs` back the two new CLI verbs.

**176 library exports, 56 runtime-module exports and 7 prelude bindings added;
none removed.**

### Breaking

- **`(web json)` has one spelling per value.** A JSON array is a **vector** and
  nothing else — a plain list is refused with a message naming `list->vector`.
  A symbol is not a JSON value on the way out, in either position, except
  `null`; an object key must be a string. Previously a list could serialise as
  an array *or* as an object depending on its contents, and `'foo` and `"foo"`
  produced the same document.
- **`(display -0.0)` prints `-0.0`.** It printed `0.0`; the sign survived in the
  bits and in arithmetic but not in the text. `json->string` follows.
- **Unknown string escapes and unrecognised `#` syntax raise.** `"\q"` used to
  read as the letter `q`, and an unimplemented `#` form used to answer an
  end-of-input object that flowed into the data as a value.
- **A character literal above U+007F is refused on both hosts.** Strings in this
  runtime are UTF-8 byte sequences and the self-hosted reader has no spelling
  for such a literal; accepting it on one host only would give the two hosts
  different sets of valid programs.

### Fixed — numbers

- `exact->inexact` is correctly rounded. Rounding happened at 53 bits and the
  result was then scaled into place, rounding a second time below the normal
  floor; the bits are dropped once now, at the width the result actually has. A
  standing measurement of 200 random subnormal decimals went from 26 wrong to 0.
- The flonum printer prints the integer part exactly at any magnitude. Values at
  or above 2^29 printed as `<big-flonum>` — text no parser accepts — and
  `json->string` returned it as success.
- The literal encoder handles every shape an f64 can take: subnormals (which
  killed the compiler with `invalid value -129`), both infinities (`+inf.0` hung
  it in a loop that never ended), NaN (silently encoded as `1.0`), and both
  zeros (a negative zero encoded as positive).
- `list?` terminates on a circular list, as the standard requires. It looped
  forever with no output.
- `equal?` compares bytevectors by content; it fell through to `eqv?`, so two
  bytevectors with identical bytes were never equal.
- `js->number` narrows on the **closed** fixnum range; both endpoint values
  arrived as flonums.
- `(json->string 1+2i)` no longer traps: a JSON number is a real number, not
  merely an exact one.

### Fixed — the reader

- The self-hosted reader accepts what the host accepts: exponent notation with
  all five markers (`e s f d l`), a leading `+`, `.5` and `5.`, the `+inf.0` /
  `+nan.0` spellings, radix and exactness prefixes (`#b #o #d #x #e #i`) in
  either case and either order, at any base under one rule — an exponent marker
  is a letter that is not a digit in the current radix, so `#x1e3` is 483 while
  `#o1e3` is 8³. A generated 6504-row corpus compares the reader against Chez
  Scheme with zero mismatches; the deliberate divergences are listed in the
  generator that builds it.
- The full R6RS string escape set translates, and `\xNN;` encodes to UTF-8
  rather than reading as its own four characters.
- `|...|` symbol names and `\xNN;` in bare identifiers are read; the writer
  emits escapes for any name whose plain spelling would not read back, so a
  symbol containing a space, or an empty symbol, survives a round trip.
- `#| ... |#` block comments nest, and `#;` skips one datum, including inside a
  list and before a dotted tail.
- `#vu8(...)` is read — the writer had always emitted it, so the library could
  not read back its own output.
- The reader's nesting limit, dropped during a port, is restored.
- A negative zero keeps its sign through the JSON reader, the decimal reader and
  the exact-to-float conversion.
- Line endings follow the host: LF, CR, CRLF, NEL, CR+NEL and LS end a line
  wherever a line can end — in a comment, in a string body, and after a
  continuation backslash.
- A source file that is not valid UTF-8 is refused by name on both hosts.
- `set!` of a non-identifier says so instead of reporting an unbound variable.

### Fixed — the two hosts agree

- The hosted driver decodes source as UTF-8 and hands the compiler bytes. It
  read source as latin-1 so raw UTF-8 would pass through, but a `\xNN;` escape
  in the same literal became a code point and was then truncated: `"\x3bb;"`
  compiled to one byte on the host and two under self-hosting, and the JS target
  crashed outright.
- `errorf` has one contract on both hosts. The compiler sources got Chez's
  `errorf` under the hosted driver and the prelude's when self-hosted; the two
  never agreed on what a message means, so `unbound variable ~s` printed with
  the name filled in under one host and with a literal `~s` under the other. All
  48 message strings drop their format directives, and a new test compiles the
  same source with both drivers and compares what they say.

### Changed

- One `(fl ...)` renderer serves both GLSL and WGSL. They had separate
  implementations and the WGSL one ignored the width argument, so the same
  shader source produced values ten times apart on the two backends.
- GLSL and WGSL refuse reserved words where a shader declares a name.
- `goeteia verify` and `goeteia pack` join the CLI.
- `docs/limits.md` declares the number syntax accepted beyond R6RS — fractions
  and exponents at any radix — and what is still refused.

---

## 1.5.7 — 2026-08-07

*37 commits.* The `(gfx gltf)` hardening cycle.

### API

`(gfx gltf)` gains 11 exports: `gltf-skin-shader` — the skin combinator over
vertex shaders — `gltf-prim-world`, and the material slots `gprim-layout`,
`gprim-etex`, `gprim-ntex`, `gprim-otex`, `gprim-emissive`,
`gprim-emissive-img`, `gprim-normal-img`, `gprim-occlusion-img`.
`(gfx fx)` gains `fx-program-attribute-names`, `fx-program-attribute-schema`
and `fx-uniform?`. **14 added, none removed.**

### Fixed

- Sampler interpolation is honoured; `WEIGHTS_0` is dequantized; quantization,
  poses and materials corrected across models; interrupted and instant fades;
  the skinned primitive's world transform; attribute widths checked in
  `gltf-draw!`; an attribute declared after `main` is refused.
- Browser compiler diagnostics are preserved; external auto artifact URLs are
  encoded; stale glyph event listeners are retired; conjure's two-file artifact
  checks are enforced; the external JS fallback runs in isolation; the optimizer
  preserves fallible dead initializers; loop retirement is scoped to mounts;
  glyph lifecycles are scoped and disposed.

---

## 1.5.6 — 2026-08-03

*76 commits.* The JavaScript backend and mount points. No library export
changed; the new surface is at the compiler and CLI level.

### API — toolchain

- **`--js`** compiles to a plain-JavaScript ES module, so a page can run where
  Wasm GC is unavailable. The numeric tower rides native `BigInt`; pairs are
  tagged object literals; non-self tail calls are trampolined, with the
  trampoline elided where chains cannot cycle; the kernel ships by reachable
  group.
- **`conjure`** and the `define-` family of mount-point wrappers stage
  compilation into the host page, dispatching on the head's shape, usable inside
  libraries, with quasiquote suspending a mount and unquote resuming it.
  `define-js` takes a URL form. `goeteia-mount` assembles the two-artifact
  section.
- **`compileGoeteiaFrom`** makes compile-in-the-browser a runtime primitive.
  `rt/web.mjs` also gains `compileGoeteia`, `runGoeteiaBytes`,
  `runGoeteiaInline`, `loadGoeteiaAuto` and `hasWasmGC`, and the new
  `rt/runjs.mjs` runs a JS-target module. **8 runtime exports added.**
- `%target-case` selects code per target.

### Fixed — the JS target

SIMD overlap semantics; real memory growth; traps for integer division by zero,
collection bounds, byte memory bounds and invalid float conversions; dynamic
minimum arity; Unicode export names; operand validation for flonums, pairs,
tagged integers and collections; a plain `ArrayBuffer` fallback when
`WebAssembly` is absent; BigInt normalization bounds.

### Fixed — elsewhere

Dead-code elimination recognises pure construction in top-level initializers,
and no longer swallows observable failures; `define-js` filesystem URLs are
percent-encoded; atomic quasiquote mount scanning; `glyphs-dodge!` retires its
loop on re-run.

---

## 1.5.5 — 2026-07-31

*35 commits.* A security and robustness pass, largely from external
contributions. No API change.

### Fixed

Dev server path containment; JSON number exponents are bounded; CLI output and
playground source are UTF-8; React prop keys and values are tracked; direct
scripts with file URLs are detected; comments are skipped in import clauses;
UASTC scratch stays inside the decoder; Zstd input and output bounds are
enforced, and literal scratch is bounded to the caller's real length; KTX
container ranges are validated; each module instance gets isolated memory; scene
camera cache keys compare completely; tangent spheres stay inside frustums;
command capacity is checked before writes; framebuffers are registered for
restarted XR sessions.

---

## 1.5.3 — 2026-07-18

*5 commits.* No API change.

- **Fixed:** `(web js)` caches JS `true` / `false` so `->js` never re-enters
  argument marshalling.
- The bump was reverted once and re-applied; the published artifact is the
  second one.

---

## 1.5.2 — 2026-07-16

*4 commits.* No API change.

- **Changed:** `(gfx glsl)`'s `(fl ...)` takes a width, for fractions with
  leading zeros.
- **Fixed:** the skybox ball mirrors the sky at grazing angles, so the waterline
  fuses instead of seaming.

---

## 1.5.1 — 2026-07-15

*7 commits.*

### API

`(gfx wgsl)` gains `wgsl-compute->string`. **1 added, none removed.**

### Added

Compute shaders in `(gfx wgsl)` — structs, storage arrays, `gid` — one dialect
fewer between the two GPU paths; `@media` blocks in `(web component)` carry
descendant and pseudo sub-rules, so a component's responsive shape travels with
it.

### Fixed

Malformed `sgl` forms are named instead of trapping; `(gfx zstd)` handles
multi-block frames with persistent entropy state and a bignum-free literals
header; `(web glyphs)` calibrates its advance scale against a DOM probe, so
canvas drift on Firefox no longer wraps text the browser fits.

---

## 1.5.0 — 2026-07-15

*11 commits.*

### API

`(gfx sgpu)` gains `sgpu-occlusion!`. **1 added, none removed.**

### Added

- **Script mode.** `(%opt 0)` or `--script` turns the optimization passes off
  for fast compiles; the cheap older passes stay on.
- `KHR_mesh_quantization` — integer vertex formats — in `(gfx gltf)`; hi-Z
  occlusion culling and GPU-side back-to-front sorting of translucent instances
  in `(gfx sgpu)`; static instanced groups in `(gfx scene)` skip the per-frame
  re-cull and re-upload.

---

## 1.3.8 — 2026-07-14

*12 commits.*

### API

**New libraries:** `(gfx uastc)`, `(web component)` — with `define-component` —
and `(web glyphs)` (7 exports). `(gfx fx)` gains the `fx-mesh` handles
(`fx-mesh!`, `fx-mesh-use!`, `fx-mesh-draw!`, `fx-mesh-count`, `fx-mesh?`);
`(gfx ktx)` gains `ktx-uastc?` and `ktx-uastc-level!`; `(web css)` gains
`palette->root`; `(web dom)` gains `computed-style` and `computed-px`.
**23 added, none removed.**

### Added

`cond`'s `=>` arrow clauses; UASTC LDR 4×4 to RGBA from the basisu transcoder,
and end-to-end UASTC KTX2 decoding; element-attached CSS interned to classes.

### Fixed

Macros defined and used within one library now expand, which removed the
in-library caveat from `(web component)`.

### Changed

The site's working parts moved into the library, and fifteen copies of the
upload dance in the examples retired.

---

## 1.3.7 — 2026-07-14

*23 commits.* Compiler codegen and the compressed-asset pipeline.

### API

**New libraries:** `(gfx meshopt)` — the EXT_meshopt_compression decoder —
`(gfx zstd)` — a Zstandard decompressor from RFC 8878 — and `(gfx sgpu)`, the
declarative scene on WebGPU. `(gfx mesh)` gains `mesh-optimize!`, `mesh-remap!`
and `mesh-acmr`; `(gfx gpu)` gains `gpu-hzb!`, `gpu-hzb-init!`,
`gpu-compute-groupx!`, `gpu-end-pass!`, `gpu-pipeline2-blend!`; `(gfx ktx)`
gains `ktx-stream!` and `ktx-alpha?`; `(gfx gl)` gains `cmd-depth-write!` and
`gl-texture-base-level!`. **25 added, none removed.**

### Added

Named lets lower to Wasm loops — no closure, no call per iteration — and loop
variables earn typed `f64` / `i32` slots across iterations; flonum function
specialization for top-level functions with f64 parameters; Forsyth vertex-cache
ordering; hierarchical-Z occlusion culling; static welding of strangers into one
draw; scene translucency as a back-to-front blended pass.

### Changed

`%f32x4-axpy!` was fused to `relaxed_madd` and then reverted to portable
mul+add after cross-engine benchmarks; the benchmark harness ships.

---

## 1.3.6 — 2026-07-14

*3 commits.*

### API

`(gfx ktx)` gains `ktx-fetch!` and `ktx-upload!`. **2 added, none removed.**

### Added

**The i32 context** — raw machine integers in locals — with an ordering fix.

---

## 1.3.5 — 2026-07-14

*11 commits.*

### API

**New library:** `(gfx ktx)`, the Basis Universal transcoder written in Scheme
from the spec (11 exports). `(gfx gpu)` gains `gpu-draw-indirect!`,
`gpu-draw-indexed-indirect!`, `gpu-indirect!`, `gpu-compute-group*!`,
`gpu-gpu-timer!`, `gpu-gpu-ms`; `(gfx gl)` gains `gl-texture-compressed!`,
`gl-compressed-level!`, `gl-compressed-family`. **20 added, none removed.**

`rt/web.mjs` gains `loadGoeteiaWorker`, with the new `rt/worker.mjs`.

### Added

GPU-driven culling with compute-compacted instances and indirect draws; the
render loop leaves the main thread;
WebGPU frame time through timestamp queries.

### Changed

The f64 context widens — per-binding capture, flonum `if`s, unboxed `fl` tests;
scene matrices cache against a transform generation; singles draw nearest first
and textured passes group by texture; animation channels sample through a play
cursor.

---

## 1.3.3 — 2026-07-14

*11 commits.*

### Breaking

- **`(web typeset canvas)` becomes `(web canvas)`.**
- **Wire format:** `(web sexpr)` and `(web rpc)` encode and decode flonums as
  `#f8"<IEEE base64>"`.

### API

`(gfx mat)` gains the destructive v3 operations (`v3-add!`, `v3-sub!`,
`v3-scale!`, `v3-cross!`, `v3-normalize!`, `v3-copy!`, `v3-set!`),
`m4s-tqs!` and `sphere-in-frustum-xyz?`; `(gfx gl)` gains the texture-array and
GPU-timer entries; `(gfx mesh)` gains `mesh-write-f16!` and
`mesh-vertex-bytes-f16`; `(gfx gltf)` gains `gltf-joint-palette!` and
`gltf-joint-count`; `(gfx fx)` gains `fx-texture-array!`. **23 added, 1 removed
(the renamed library).**

### Changed

v3 hot paths stop allocating; the instanced cull goes SIMD; scene frame globals
ride one `Env` uniform block; skeletons go SIMD-resident; half-precision vertex
streams; texture arrays; GPU frame time in the stats HUD.

---

## 1.3.2 — 2026-07-13

*2 commits.*

### Breaking — the library split

**330 exported names move.** Every graphics library leaves the `web` prefix for
`gfx`, and audio becomes `(aud sfx)`:

| before | after |
|---|---|
| `(web audio)` | `(aud sfx)` |
| `(web collide)` `(web fx)` `(web gl)` `(web glsl)` `(web gltf)` `(web gpu)` `(web ibl)` `(web mat)` `(web mesh)` `(web post)` `(web scene)` `(web sdf)` `(web sprite)` `(web stats)` `(web wgsl)` `(web xr)` | the same names under `gfx` |

The exported names themselves are unchanged; only the library each lives in
moved. `(web ...)` keeps the browser and document libraries.

---

## 1.3.1 — 2026-07-13

*8 commits.*

### API

`(web mat)` gains the staging matrices `m4s-identity!`, `m4s-mul!`, `m4s-trs!`,
`m4s-read`, `m4s-write!`; `(web gpu)` gains `gpu-bundle!` and `gpu-execute!`;
`(web gl)` gains `cmd-uniform-matrix4s!`. **8 added, none removed.**

### Added

The uniform cache; same-geometry single-draw batching and LOD containers in
`(web scene)`; render bundles; the cached shadow map; `fx-skybox` with a sea
that mirrors.

---

## 1.3.0 — 2026-07-13

*31 commits.* The graphics stack becomes an engine.

### API

**New libraries:** `(web gpu)` — the command buffer on WebGPU, 27 exports —
`(web post)` (15), `(web xr)` (7), `(web wgsl)`, `(web sexpr)`, `(web stats)`,
`(web ibl)`, `(web sdf)`. `(web collide)` gains capsules, the swept sphere, the
character controller and the broadphase grid (13); `(web gl)` gains the 32-bit
index and MRT entries (7); `(web gltf)` gains the animation state machine (6);
`(web fx)` gains `fx-loop-fixed!`, `fx-target-mrt!`, `fx-mrt-texture`.
**89 added, none removed.**

### Added

Post-processing chains including depth of field, grade and FXAA; light probes;
deferred shading; one shader source in three dialects; sharp SDF text; the
engine layer (fixed timestep, character controller, broadphase); PCSS soft
shadows and screen-space reflections; Wasm SIMD in the compiler, with `m4-mul`
3.5× wide; 32-bit indices for meshes past 65536 vertices.

---

## 1.2.0 — 2026-07-13

*38 commits.* The 3D renderer.

### API

No new libraries; **74 exports added** to the existing ones. `(web gl)` gains
26 — instancing, cube maps, UBOs, VAOs, transform feedback, MSAA resolve;
`(web fx)` gains 17 render-target entries; `(web gltf)` gains 14 —
`gltf-animate!`, `gltf-animate-blend!`, `gltf-joint-matrices`,
`gltf-load-textures!`, `gltf-weights!`; `(web mesh)` gains 9 — `mesh-bounds`,
`mesh-heightmap`, `mesh-tangents`, the PBR and normal-mapping shaders;
`(web mat)` gains `m4-inverse`, `m4-ortho`, `m4-unproject`,
`m4-frustum-planes`, `sphere-in-frustum?`; `(web glsl)` gains the ES 3.00
dialect entries. **None removed.**

### Added

WebGL 2 and offscreen render targets; instancing; glTF textures, skeletal
animation and morph targets; shadow mapping with PCF and cascades; bloom; normal
mapping; cube maps; particles; mipmaps; linear-space lighting; MSAA; picking;
animation crossfade; frustum culling; Cook-Torrance GGX PBR with the sky as a
light probe; terrain from a height function; water; HDR half-float targets;
SSAO; point-light shadows; GPU particles through transform feedback.

### Fixed

The mesh index writer stores u16 pairs as byte stores rather than packed i32;
anti-feedback-loop opcodes (`cmd-unbind-texture!`, `cmd-unbind-cubemap!`) for
what Chrome rejects.

### Changed

The command region grows from 16 KiB to 64 KiB — the old budget was a 2D budget.

---

## 1.1.0 — 2026-07-13

*10 commits.*

### Breaking

**`(web three)` is removed**, with its 6 exports (`s3d`, `three-loop!`,
`three-ref`, `three-render!`, `three-renderer`, `$s3d-build`). The Three.js
binding is gone; the native stack replaces it.

### API

**New libraries:** `(web gltf)` — `gltf-parse`, `gltf-fetch!`, `gltf-draw!`,
`gltf-prims` and the `gprim-` accessors — `(web collide)` — `ray-sphere`,
`ray-aabb`, `ray-mesh`, `ray-triangle`, `ray-plane`, `sphere-sphere?`,
`sphere-aabb?`, `aabb-aabb?`, `sphere-aabb-push` — and `(web audio)` —
`audio-init!`, `beep!`, `play!`, `load-sound!`, `loop-sound!`, `stop-sound!`,
`audio-time`. `(web mesh)` gains the UV entries; `(web mat)` gains
`m4-from-quat`; `(web fx)` gains pointer lock. **37 added, 6 removed.**

### Added

`(web typeset)` kinsoku line breaking; a textured lit shader; GLB static meshes
from real assets.

---

## 1.0.2 — 2026-07-13

*4 commits.*

### API

**New libraries:** `(web fx)` (24 exports) — the frame loop, programs, targets
and input — `(web mat)` (23), `(web mesh)` (15), `(web sprite)` (22),
`(web typeset)` (13), `(web scroll)` (6), `(web scene)` (4),
`(web typeset canvas)`. `(web gl)` gains 12 command entries; `(web glsl)` gains
`glsl-attributes` and `glsl-uniforms`. **122 added, none removed.**

`rt/compile.mjs` gains `compileSource`, and `rt/repl.mjs` adds `startRepl`.

### Added

The graphics, text and 3D web stack, plus compiler ergonomics.

---

## 1.0.1 — 2026-07-12

*4 commits.* No API change.

- **Changed:** the playground ships inside the npm package.

---

## 1.0.0 — 2026-07-12

*66 commits.* The first published version: a self-hosting Scheme compiler
targeting WebAssembly GC, and a web stack written in the language it compiles.

### API

**15 libraries, 111 exports.** `(web reactive)` — fine-grained signals, effects
and batching — `(web sx)` — reactive DOM templates — `(web react)`,
`(web dom)`, `(web html)`, `(web css)`, `(web js)`, `(web json)`, `(web rpc)`,
`(web fetch)`, `(web ws)`, `(web sse)`, `(web gl)` — raw WebGL through a
command buffer — `(web glsl)`, and `(web three)` (removed in 1.1.0).

### The compiler

Seven milestones: a Scheme subset to Wasm GC end to end; closures, `set!` and
top-level variables; strings, symbols and characters; variadic procedures,
`apply` and `values`; `read`, `write` and runtime symbol interning; hygienic
macros; **self-hosting**. Then `call/cc` as escape continuations over Wasm
exception handling, `dynamic-wind`, the numeric tower (bignums, flonums with
fixnum fast paths, rationals, complex numbers), vectors, bytevectors,
hashtables, `define-record-type`, ports, `guard` / `raise`, the library system
with import resolution and splicing, and dead-code elimination with predicate
test fusion.

### The toolchain

**Six runtime modules, 10 exports:** `rt/compile.mjs` (`compileFile`,
`compileToBytes`), `rt/run.mjs` (`runModule`, `decode`), `rt/web.mjs`
(`loadGoeteia`), `rt/jsbridge.mjs` (`makeJsBridge`, `callMain`,
`jsBridgeStubs`), `rt/react.mjs` (`goeteiaComponent`) and `rt/dev.mjs`
(`startDevServer`). The browser playground; the npm package and CLI.
