# Changelog

Every published version of Goeteia, newest first.

> **What counts as a release.** Version numbers and dates come from the npm
> registry — `npm view goeteia versions` — which is the record of what was
> actually shipped. Where a git tag or a `package.json` bump in the repository
> disagrees, npm wins. Three numbers were never published and so are absent
> here: `1.3.4`, `1.5.4`, and the whole `1.4` line. Commit counts are the
> distance from the previous published version.

---

## 1.5.8 — 2026-09-01

*123 commits.* Numeric and reader conformance. Every change in this release
landed with a test that was red before it, and the whole cycle was driven by
mutation testing: a claim that no mutation could redden was treated as a defect
in the claim.

### Breaking

- **`(web json)` has one spelling per value.** A JSON array is a **vector** and
  nothing else — a plain list is refused with a message naming `list->vector`.
  A symbol is not a JSON value on the way out, in either position, except
  `null`; an object key must be a string. Previously a list could serialise as
  an array *or* as an object depending on its contents, and `'foo` and `"foo"`
  produced the same document.
- **`(display -0.0)` prints `-0.0`.** It printed `0.0`; the sign survived in the
  bits and in arithmetic but not in the text.
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
- `list?` terminates on a circular list, as R7RS requires. It looped forever
  with no output.
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
  symbol containing a space or an empty symbol survives a round trip.
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
  48 message strings drop their format directives, and a new cell compiles the
  same source with both drivers and compares what they say.

### Added

- `(gfx glb)` — write standard GLB from staging memory, including skins, node
  trees and animation clips.
- `(gfx retarget)` — bone-length-preserving clip retargeting.
- `(gfx image)` — PNG and TGA codecs in pure Scheme.
- `(gfx raster)` — a CPU rasterizer, byte-identical to its reference
  implementation, with textured shading and CPU skinning.
- `goeteia verify` and `goeteia pack` — the LLM substrate ships.
- Inverse trigonometry, quaternion slerp, R6RS division operators and top-level
  trigonometry in the prelude; pixel readback through the command buffer.
- GLSL and WGSL refuse reserved words where a shader declares a name.

### Changed

- One `(fl ...)` renderer serves both GLSL and WGSL. They had separate
  implementations and the WGSL one ignored the width argument, so the same
  shader source produced values ten times apart on the two backends.
- `docs/limits.md` declares the number syntax accepted beyond R6RS — fractions
  and exponents at any radix — and what is still refused.

---

## 1.5.7 — 2026-08-07

*37 commits.* The `(gfx gltf)` hardening cycle.

- **Added:** `gltf-skin-shader`, the skin combinator over vertex shaders, with
  attribute and uniform contract checks; `TANGENT` and `COLOR_0` attributes;
  material texture slots and layouts.
- **Fixed:** sampler interpolation is honoured; `WEIGHTS_0` is dequantized;
  quantization, poses and materials corrected across models; interrupted and
  instant fades; the skinned primitive's world transform; attribute widths
  checked in `gltf-draw!`; an attribute declared after `main` is refused.
- **Fixed:** browser compiler diagnostics are preserved; external auto artifact
  URLs are encoded; stale glyph event listeners are retired; conjure's
  two-file artifact checks are enforced; the external JS fallback runs in
  isolation; the optimizer preserves fallible dead initializers; loop retirement
  is scoped to mounts; glyph lifecycles are scoped and disposed.

---

## 1.5.6 — 2026-08-03

*76 commits.* The JavaScript backend and mount points.

- **Added: a JavaScript target.** `--js` compiles to a plain ES module — no
  WebAssembly — so a page can run where Wasm GC is unavailable. The numeric
  tower rides native `BigInt`; pairs are tagged object literals; non-self tail
  calls are trampolined, with the trampoline elided where chains cannot cycle;
  the kernel ships by reachable group.
- **Added: conjure.** Mount points stage compilation into the host page:
  `conjure` and the `define-` family of wrappers, dispatching on the head's
  shape, usable inside libraries, with quasiquote suspending a mount and
  unquote resuming it. `goeteia-mount` assembles the two-artifact section.
  `(web embed)` was folded into conjure and removed.
- **Added:** compile-in-the-browser as a runtime primitive (`compileGoeteiaFrom`).
- **Fixed (JS target):** SIMD overlap semantics; real memory growth; traps for
  integer division by zero, collection bounds, byte memory bounds and invalid
  float conversions; dynamic minimum arity; Unicode export names; operand
  validation for flonums, pairs, tagged integers and collections; a plain
  `ArrayBuffer` fallback when `WebAssembly` is absent; BigInt normalization
  bounds.
- **Fixed:** dead-code elimination recognises pure construction in top-level
  initializers, and no longer swallows observable failures; `define-js`
  filesystem URLs are percent-encoded; atomic quasiquote mount scanning;
  `glyphs-dodge!` retires its loop on re-run.

---

## 1.5.5 — 2026-07-31

*35 commits.* A security and robustness pass, largely from external
contributions.

- **Fixed:** dev server path containment; JSON number exponents are bounded;
  CLI output and playground source are UTF-8; React prop keys and values are
  tracked; direct scripts with file URLs are detected; comments are skipped in
  import clauses; UASTC scratch stays inside the decoder; Zstd input and output
  bounds are enforced (and literal scratch is bounded to the caller's real
  length); KTX container ranges are validated; each module instance gets
  isolated memory; scene camera cache keys compare completely; tangent spheres
  stay inside frustums; command capacity is checked before writes; framebuffers
  are registered for restarted XR sessions.

---

## 1.5.3 — 2026-07-18

*5 commits.*

- **Fixed:** `(web js)` caches JS `true` / `false` so `->js` never re-enters
  argument marshalling.
- The bump was reverted once and re-applied; the published artifact is the
  second one.

---

## 1.5.2 — 2026-07-16

*4 commits.*

- **Changed:** `(gfx glsl)`'s `(fl ...)` takes a width, for fractions with
  leading zeros.
- **Fixed:** the skybox ball mirrors the sky at grazing angles, so the waterline
  fuses instead of seaming.

---

## 1.5.1 — 2026-07-15

*7 commits.*

- **Added:** `(gfx wgsl)` grows compute — structs, storage arrays, `gid` — one
  dialect fewer between the two GPU paths; `@media` blocks in `(web component)`
  carry descendant and pseudo sub-rules, so a component's responsive shape
  travels with it.
- **Fixed:** malformed `sgl` forms are named instead of trapping; `(gfx zstd)`
  handles multi-block frames with persistent entropy state and a bignum-free
  literals header; `(web glyphs)` calibrates its advance scale against a DOM
  probe, so canvas drift on Firefox no longer wraps text the browser fits.

---

## 1.5.0 — 2026-07-15

*11 commits.*

- **Added: script mode.** `(%opt 0)` or `--script` turns the optimization passes
  off for fast compiles; the cheap older passes stay on.
- **Added:** `KHR_mesh_quantization` — integer vertex formats — in
  `(gfx gltf)`; hi-Z occlusion culling and GPU-side back-to-front sorting of
  translucent instances in `(gfx sgpu)`; static instanced groups in
  `(gfx scene)` skip the per-frame re-cull and re-upload.

---

## 1.3.8 — 2026-07-14

*12 commits.*

- **Added:** `cond`'s `=>` arrow clauses; `(gfx uastc)` — UASTC LDR 4×4 to RGBA
  from the basisu transcoder — and end-to-end UASTC KTX2 decoding;
  `(web component)` with `define-component` and element-attached CSS interned to
  classes; `(web glyphs)`.
- **Fixed:** macros defined and used within one library now expand, which
  removed the in-library caveat from `(web component)`.
- **Changed:** the site's working parts were extracted into the library —
  `fx-mesh` handles, `palette->root`, `computed-style` — and fifteen copies of
  the upload dance in the examples retired.

---

## 1.3.7 — 2026-07-14

*23 commits.* Compiler codegen and the compressed-asset pipeline.

- **Added:** named lets lower to Wasm loops — no closure, no call per iteration
  — and loop variables earn typed `f64` / `i32` slots across iterations; flonum
  function specialization for top-level functions with f64 parameters.
- **Added:** `mesh-optimize!` (Forsyth vertex-cache ordering, with `mesh-acmr`
  to prove it), `mesh-remap!`, hierarchical-Z occlusion culling, static welding
  of strangers into one draw, scene translucency as a back-to-front blended
  pass, `(gfx sgpu)` — the declarative scene on WebGPU, culled where it lives —
  and `(gfx meshopt)` and `(gfx zstd)`, both decoders written from the specs.
- **Changed:** `%f32x4-axpy!` was fused to `relaxed_madd` and then reverted to
  portable mul+add after cross-engine benchmarks; the benchmark harness ships.

---

## 1.3.6 — 2026-07-14

*3 commits.*

- **Added: the i32 context** — raw machine integers in locals — together with an
  ordering fix; the transcoder's design notes; `examples/fx-ktx`.

---

## 1.3.5 — 2026-07-14

*11 commits.*

- **Added:** `(gfx ktx)` — the Basis Universal transcoder, in Scheme, from the
  spec; GPU-driven culling with compute-compacted instances and indirect draws;
  the render loop leaves the main thread (`loadGoeteiaWorker` + `rt/worker.mjs`);
  WebGPU frame time through timestamp queries.
- **Changed:** the f64 context widens — per-binding capture, flonum `if`s,
  unboxed `fl` tests; `%f32x4-dot`; scene matrices cache against a transform
  generation; singles draw nearest first and textured passes group by texture;
  animation channels sample through a play cursor.

---

## 1.3.3 — 2026-07-14

*11 commits.*

- **Breaking:** `(web typeset canvas)` flattens to `(web canvas)`.
- **Breaking (wire format):** `(web sexpr)` and `(web rpc)` encode and decode
  flonums as `#f8"<IEEE base64>"`.
- **Changed:** v3 hot paths stop allocating (destructive v3 ops, unboxed culls,
  scalar slab sweep); the instanced cull goes SIMD; scene frame globals ride one
  `Env` uniform block; skeletons go SIMD-resident; half-precision vertex streams
  via `mesh-write-f16!`; texture arrays; GPU frame time in the stats HUD.

---

## 1.3.2 — 2026-07-13

*2 commits.*

- **Breaking: the library split.** `(web ...)` becomes `(web ...)`,
  `(gfx ...)` and `(aud sfx)`. Graphics and audio libraries move out of the
  `web` prefix.

---

## 1.3.1 — 2026-07-13

*8 commits.*

- **Added:** `m4s` staging matrices and the uniform cache; same-geometry
  single-draw batching and LOD containers in `(web scene)`; render bundles in
  `(web gpu)`; the cached shadow map; `fx-skybox` with a sea that mirrors.

---

## 1.3.0 — 2026-07-13

*31 commits.* The graphics stack becomes an engine.

- **Added:** `(web post)` post-processing chains — including depth of field,
  grade and FXAA; `(web ibl)` light probes; MRT and deferred shading;
  `(web collide)` capsules, swept spheres and move-and-slide; `anim-machine`
  over glTF clips; `(web scene)` with materials, frustum culling and groups;
  `(web gpu)` — the command buffer on WebGPU, with depth, indices, a uniform
  struct, compute passes, instancing and textures; `(web wgsl)` — one shader
  source, three dialects; `(web sdf)` sharp text; `(web xr)`; `(web stats)`;
  `(web sexpr)`, an s-expression wire codec matching Igropyr's extended format;
  the engine layer (fixed timestep, character controller, broadphase); PCSS soft
  shadows and screen-space reflections.
- **Added:** the compiler learns Wasm SIMD, and `m4-mul` goes 3.5× wide.
- **Added:** 32-bit indices — meshes and assets past 65536 vertices.

---

## 1.2.0 — 2026-07-13

*38 commits.* The 3D renderer.

- **Added:** WebGL 2 and offscreen render targets; instancing; glTF textures,
  skeletal animation and morph targets; shadow mapping with PCF and cascades;
  bloom; normal mapping; cube maps; particles; mipmaps; linear-space lighting;
  MSAA; picking via `m4-inverse` and `m4-unproject`; animation crossfade;
  frustum culling; Cook-Torrance GGX PBR with the sky as a light probe; terrain
  from a height function; water; HDR half-float targets; SSAO; point-light
  shadows; VAOs; UBOs; GPU particles through transform feedback; the ES 3.00
  GLSL dialect.
- **Fixed:** the mesh index writer stores u16 pairs as byte stores rather than
  packed i32; anti-feedback-loop opcodes (`cmd-unbind-texture!`,
  `cmd-unbind-cubemap!`) for what Chrome rejects.
- **Changed:** the command region grows from 16 KiB to 64 KiB — the old budget
  was a 2D budget.

---

## 1.1.0 — 2026-07-13

*10 commits.*

- **Breaking:** `(web three)` is removed. The Three.js binding is gone; the
  native stack replaces it.
- **Added:** `(web typeset)` with kinsoku line breaking; `(web collide)`;
  `(web audio)`; texture coordinates and a textured lit shader in `(web mesh)`;
  `(web gltf)` — GLB static meshes from real assets; pointer lock in `(web fx)`.

---

## 1.0.2 — 2026-07-13

*4 commits.*

- **Added:** the graphics, text and 3D web stack, plus compiler ergonomics.

---

## 1.0.1 — 2026-07-12

*4 commits.*

- **Changed:** the playground ships inside the npm package; the last `schwasm`
  names become `goeteia`.

---

## 1.0.0 — 2026-07-12

*66 commits.* The first published version: a self-hosting Scheme compiler
targeting WebAssembly GC, and a web stack written in the language it compiles.

- **The compiler**, in seven milestones: a Scheme subset to Wasm GC end to end;
  closures, `set!` and top-level variables; strings, symbols and characters;
  variadic procedures, `apply` and `values`; `read`, `write` and runtime symbol
  interning; hygienic macros; **self-hosting**. Then `call/cc` as escape
  continuations over Wasm exception handling, `dynamic-wind`, the numeric tower
  (bignums, flonums and fixnum fast paths, rationals, complex numbers), vectors,
  bytevectors, hashtables, `define-record-type`, ports, `guard`/`raise`, the
  library system with import resolution and splicing, and dead-code elimination
  with predicate test fusion.
- **The web stack:** `(web reactive)` fine-grained signals; `(web sx)` reactive
  DOM templates; `(web react)`; `(web html)`; `(web css)` — every value
  expressible under one uniform rule; `(web json)`; `(web rpc)`; `(web fetch)`
  over JSPI; `(web ws)` and `(web sse)`; `(web gl)` — raw WebGL through a
  command buffer; `(web glsl)`; `(web three)` (removed in 1.1.0).
- **The toolchain:** `rt/dev.mjs`, a project-agnostic live-reload dev server;
  the browser playground; the npm package and CLI.
- Renamed from *schwasm* to **Goeteia** during this cycle.
