# Goeteia

*Γοητεία — the black ars of commanding what lies beneath.*

**[goeteia.dev](https://goeteia.dev)**

A pure-Scheme web toolkit, compiled to WebAssembly.

Goeteia is a Scheme-to-WebAssembly compiler built on the WebAssembly
GC extension (Wasm 3.0).  It is an independent implementation written
from the R6RS and WebAssembly specifications, and it compiles itself:
the compiler is written in the Scheme subset it compiles, and the
self-hosted build reproduces itself byte-for-byte.

Scheme values live in the Wasm engine's garbage-collected heap:
fixnums are unboxed `i31ref`s, pairs are GC structs, and `eq?` is a
single `ref.eq` instruction.  Compiled modules contain no host-side
object representation at all — the host supplies two byte-stream
imports for I/O and nothing else — so they run on any engine with
Wasm GC and tail calls (Node 22+, current Chrome / Firefox / Safari,
wasmtime).  Proper tail calls compile to `return_call`.

## Language

- Closures (typed function references, `call_ref`; a fast per-arity
  entry plus a generic entry, so variadic procedures and `apply` are
  cheap), proper tail calls throughout
- Hygienic macros: `define-syntax` with `syntax-rules` or procedural
  `syntax-case` (fenders, nested ellipses, `(... ...)` escapes,
  `with-syntax`, `datum->syntax`, `generate-temporaries`)
- The numeric tower minus rationals: fixnums with overflow promotion
  to bignums, flonums with contagion, exact/inexact conversions
- `call/cc` (escape continuations over wasm exception handling) and
  `dynamic-wind`
- Vectors, bytevectors, strings, interned symbols, characters,
  hashtables, `define-record-type`
- `read` / `write` / `display`, `values`, `let-values`, `assert`,
  quasiquote, `case` `do` named-`let` `letrec` internal defines
- A library system: `(import (math utils))` loads
  `math/utils.ss`-style `(library ...)` files, dependencies first
- Dead code elimination: programs carry only what they use, and a
  conservative inliner erases small helper calls
- Wasm SIMD, memory-to-memory: `%f32x4-add!/-sub!/-mul!` and the
  scalar-mixing `%f32x4-scale!`/`%f32x4-axpy!` run four f32 lanes
  per instruction over staging memory, and `%f32x4-dot` multiplies
  four lanes and sums them to one flonum (the quaternion/plane dot)
  — the v128 lives only inside
  each primitive, so no new types anywhere; modules pay for it only
  when they use it
- Compile errors carry source context (`at file:line (function)`),
  and emitted modules carry a name section, so browser stack traces
  read Scheme

See [Design](#design) for the object representation, the calling
convention, and the milestone-by-milestone build log.

## Web

The UI, text and network stack over the JS bridge, in `lib/web/`:

- `(web js)` / `(web dom)` — JavaScript interop and DOM sugar;
  Scheme closures convert to callable JS functions and back
- `(web reactive)` — fine-grained signals: `signal` / `effect` /
  `batch`, with automatic dependency tracking and ownership
- `(web sx)` — reactive DOM templates.  The `sx` macro splits a
  template at expansion time: static structure is built once,
  each unquote becomes a hole updated by its own effect — no
  virtual DOM, the DOM is a write-only surface

  ```scheme
  (define n (signal 0))
  (sx (div (span ,(signal-ref n))
           (button (@ (on-click ,(lambda _ (signal-update! n (lambda (v) (+ v 1))))))
             "+")))
  ```
- `(web html)` — the same SXML vocabulary `(web sx)` turns into live
  DOM, rendered to a *string* instead: `sxml->html` for fragments,
  `html->document` for a whole page, with text escaped, void tags
  closed, `(raw "...")` passed through for `<script>`/`<style>`.  One
  notation authors both the dynamic client and the static page
- `(web css)` — CSS as Scheme data: `css->string` renders a rule
  list (`(selector (prop value ...) ...)`) to a stylesheet, with
  variable-arity unit forms (`(em 1)` → `"1em"`, `(em 0 92)` →
  `"0.92em"`) that stay exact — no flonums, since the printer isn't
  bit-exact.  The `(web css)` of shaders is `(gfx glsl)`; this is the
  `(web css)` of pages
- `(web react)` — embed Goeteia components into an existing React
  app: `react-component` registers a factory the React side wraps
  in one `useEffect` (`rt/react.mjs`); props flow in as JS objects,
  the dispose thunk flows back as a JS function
- `(web typeset)` — DOM-free text layout, after
  [pretext](https://www.pretext.cool): `prepare` measures each
  distinct code point once, `layout` is pure arithmetic from the
  cached widths to line boxes — no DOM, no reflow, so heights are
  known before anything mounts (virtual scrolls, streaming chat) and
  text can be set in canvas/GL scenes, where there is no layout
  engine at all.  Hard breaks, space wraps, CJK breaks with kinsoku
  (closing punctuation never starts a line, opening brackets never
  end one), code-point splits for over-wide words; `(web canvas)`
  supplies the browser measurer, and the engine itself
  verifies headlessly (`examples/fx-labels.html`: labels typeset
  here, rasterized once, distance-fielded by `(gfx sdf)` and drawn
  in 3D as camera-facing quads that stay crisp at any range)
- `(web canvas)` — the browser's canvas, wrapped: today the
  measureText-backed measurer that feeds `(web typeset)`'s
  `prepare` (the one place a host appears in the text stack), and
  the home for Canvas 2D drawing sugar as it grows
- `(web scroll)` — a virtual scroller for variable-height text, the
  use case `(web typeset)` was born for: heights are typeset before
  anything mounts (no reflow-forcing measurement), only the visible
  window is in the DOM, appends stick to the bottom, and one
  offsetHeight read per newly mounted item corrects the estimates
  (`examples/chat.html`: an endless streaming feed)
- `(web sexpr)` — the s-expression wire codec, byte-for-byte
  compatible with Igropyr's `(igropyr sexpr)` extended mode:
  `sexpr->string` / `string->sexpr` over a depth- and size-limited
  whitelist — proper and dotted lists, symbols, strings, exact
  integers and ratios, vectors, bytevectors as `#vu8"<base64>"`, and
  every IEEE double as `#f8"<base64>"` — its 8 IEEE-754 bytes via a JS
  DataView, bit-exact (inf and nan included) and byte-identical to
  Chez's `bytevector-ieee-double-*` (−0.0 reads back as 0.0)
- `(web rpc)` — s-expression RPC to a Scheme backend (Igropyr's
  `(igropyr sexpr)` is the server half): serialized and parsed
  through `(web sexpr)`, so exact integers, ratios, binary and every
  IEEE double cross the wire bit-exact and there is no codec at all
- `(web fetch)` — direct-style HTTP over JSPI: `(http-get url)` reads
  like a blocking call, suspending the whole wasm stack on the
  underlying promise and resuming with the value — sequential code,
  no callbacks, no async coloring (Chrome stable; Node needs
  `--experimental-wasm-jspi`); `(web rpc)`'s `rpc` builds on it
- `(web json)` — the same safe JSON codec as the Igropyr server side
  (ported from its `json.sc`): recursive-descent parser, `\uXXXX` and
  surrogate pairs to UTF-8, exact bignums, `json-ref` path access
- `(web ws)` / `(web sse)` — pushed s-expressions: every WebSocket
  message / SSE event is one datum, matching Igropyr's
  `ws-send-sexpr!` / `sse-send-sexpr!` on the server; multi-line
  datums survive SSE framing intact

`examples/counter.html` is a page scripted entirely in Goeteia;
`examples/react-embed.html` is a React app with Goeteia widgets
inside.

## Graphics & Games

The rendering and game stack — raw WebGL/WebGPU through a command
buffer, shaders as s-expressions, and everything over them — in
`lib/gfx/`:

- `(gfx gl)` — raw WebGL through a command buffer: Scheme encodes a
  frame of GL commands as words in the shared linear memory and one
  bridge call replays them; vertex data uploads zero-copy from the
  same memory (`examples/gl-particles.html`: 10,000 particles,
  one call per frame); textures upload from a canvas or image,
  `gl-program!` binds attribute locations before linking, and indexed
  meshes draw through an element buffer with the depth test on.
  The context is WebGL 2 (with fallback): offscreen render targets
  (`examples/fx-post.html`: the scene through a ripple + vignette;
  `examples/fx-shadow.html`: PCSS soft shadows — blocker search,
  penumbra width, contact hardening — through a depth-only target; `examples/fx-bloom.html`: a five-pass HDR bloom chain
  through a half-float target, tonemapped down),
  instanced draws (`examples/fx-forest.html`: 8,000 trees, one call;
  `examples/fx-particles.html`: 4,000 sparks integrating in staging
  memory), cube maps (`examples/fx-skybox.html`: a procedural sky
  and a mirror ball reflecting it), texture arrays (many same-size
  images behind ONE bind — `sampler2DArray` picks a layer, and the
  layer index rides a per-instance attribute, so differently-skinned
  instances stay one draw), and mat4-array uniforms for
  skinning
- `(gfx glsl)` — GLSL as s-expressions: `glsl->string` is a pure
  function from a shader form list to GLSL source (the `(web css)` of
  shaders), so shaders compose with `append`/`map` and helper
  functions and verify headlessly; infix `+ - * /`, `(fl 0 50)` float
  literals (no Scheme flonums, no printer noise), `attribute`/
  `uniform`/`varying`, `for` loops (kernel sweeps: PCF, blurs), and
  `define`d functions.  The forms are dialect-neutral: the same
  shader renders as ESSL 1.00 or, via `glsl300-vs/fs->string`
  (`fx-program3!`), as `#version 300 es` — where `uniform-block`
  becomes a std140 block (`examples/fx-ubo.html`: one Env block,
  three shaders), `(out loc T name)` forms declare multiple pinned
  fragment outputs (MRT), and transform feedback captures the
  varyings (`examples/fx-gpu-particles.html`: 100,000 particles
  whose physics is a vertex shader)
- `(gfx wgsl)` — the third dialect, for WebGPU: `wgsl->string`
  renders the *same* shader forms `(gfx glsl)` renders into one WGSL
  module — the two stages' uniforms merge into a struct at
  `@group(0) @binding(0)`, varyings become the `VOut` struct, and
  `gl_Position` / `gl_FragColor` / a `sampler2D` (split into a
  sampler + texture pair) respell themselves — while `wgsl-layout`
  derives the pipeline's vertex formats from the same attribute
  declarations.  One shader source, three APIs
- `(gfx fx)` — the effects harness over `(gfx gl)`: a shader authored
  as `(gfx glsl)` forms already declares its interface, so
  `fx-program!` reads the attribute/uniform declarations back out of
  the same forms and does the wiring — locations, interleaved
  offsets, typed uniform dispatch, slot numbers, staging-memory
  allocation.  Attribute setup rides vertex array objects without
  being asked: the first `fx-use!` of a (program, buffer) pair
  records every pointer into a VAO, each later one is a single-word
  rebind.  Scalar and vector uniforms remember their last value per
  program and skip the re-send — a steady `u_light` costs one send,
  ever (matrices change every frame and stay uncached; don't mix
  raw `cmd-uniform*!` writes with `fx-uniform!` on the same name).  `fx-loop!` frames commands around a t/dt callback
  (`fx-loop-fixed!` splits it: physics at its own fixed cadence,
  render once per frame with a blend alpha);
  `fx-fullscreen!` makes a fragment-shader effect ~15 lines
  (`examples/fx-plasma.html`); `fx-target-mrt!` is a G-buffer —
  n half-float attachments one shader fills in one pass
  (`examples/fx-deferred.html`: deferred shading, 24 point lights
  for one fullscreen quad).  `fx-ticks!` (the timing pump) and
  `fx-init-input!` (polled keys/pointer) have no GL dependency, so a
  Three.js scene uses them directly; `pointer-lock!` adds captured
  relative mouse for first-person cameras
  (`examples/fx-fps.html`: click to capture, WASD to walk, SPACE to
  jump — the packaged character at a fixed 120Hz over the
  broadphase grid; `examples/arena.html` makes a game of it:
  waves of drifting orbs, `ray-sphere` shots, a sprite HUD, audio
  chirps — and shadows for free: the static world's depth map
  renders once, ever, and every frame just samples it)
- `(gfx sprite)` — 2D games over `(gfx fx)` and `(web typeset)`: a
  glyph atlas rasterizes each distinct code point once and its
  measurer doubles as typeset's `measure`, so layout and rendering
  agree glyph for glyph; sprites, solid rects and text ride one quad
  batch — one buffer upload, one draw call per frame
  (`examples/breakout.html`: bricks, ball, paddle and the score text
  in a single draw); image sprite sheets load premultiplied and draw
  source rectangles through their own batch
- `(gfx sdf)` — signed distance fields from any canvas alpha:
  `sdf-from-canvas!` grabs the raster into staging memory in one
  call and runs a two-pass chamfer transform in wasm; sample the
  result with a smoothstep around 0.5 and text re-sharpens at any
  magnification (widen it for halos, shift it for outlines — the
  field carries all of it)
- `(gfx stats)` — the performance HUD: frame time, FPS, draw calls
  and command bytes in the corner, with a 60-frame frame-time strip —
  and the GPU's own frame time beside them when the browser exposes
  the timer-query extension: every replay wraps itself in a
  TIME_ELAPSED query (`gl-gpu-timer!`/`gl-gpu-ms`), results
  surfacing a few frames behind, hidden where unsupported.
  The command buffer makes the numbers free — draws are counted as
  they encode (`cmd-draws`) and the frame's size is the write cursor
  (`cmd-pos`), so nothing is instrumented; `stats-draw!` goes last
  in the frame and never counts itself (fx-deferred wears it)
- `(gfx scene)` — reactive raw-GL scenes: the `sgl` template is to
  the GL stack what `sx` is to the DOM — geometry from `(gfx mesh)`
  builds and uploads once, each unquoted attribute becomes a
  signal-driven hole, and a frame is pure arithmetic over current
  fields.  Groups nest — children inherit the parent transform, so one
  signal swings a whole assembly — and matrices cache against a
  transform generation the signals bump: a static mesh composes its
  model matrix, world center and radius exactly once, ever; a frame
  recomputes only what actually moved.  Singles draw sorted nearest
  first (early z pays the occluded-fragment bill), textured ones
  grouped by texture first so equal textures bind once.  Meshes with the same literal
  geometry share one upload and draw as ONE instanced call: each
  visible instance's model matrix composes in closed form straight
  into the instance buffer (m4s-trs!/m4s-mul! — SIMD, no boxed
  matrix anywhere) with its color beside it, and culled instances
  simply don't join the buffer — the cull itself runs four spheres
  at a time: centers and radii lie SoA in staging and each frustum
  plane tests all four in five SIMD instructions.  Static strangers
  weld: same-color lit meshes of DIFFERENT geometry whose
  transforms no signal drives (the effects already ran, so a zero
  generation is proof) bake their model matrices into fresh vertex
  data at build and draw as ONE mesh under one conservative
  bounding sphere.  `(lod (@ (switch d ...)) mesh ...)`
  containers hold detail levels of one thing — the eye's distance
  picks which child draws, and the mesh generators' own segment
  parameters make the levels free.  Meshes pick materials
  declaratively — the lit default,
  `(texture slot)`, or `(metallic)`/`(roughness)` PBR against the
  scene's `(probe ...)` — and every frame culls each mesh's bounding
  sphere against the camera frustum before a single command is
  encoded.  The frame globals — view-projection, light, ambient,
  eye — live in one std140 Env block every scene program reads from
  binding 0: 96 bytes uploaded once per frame, no per-program
  plumbing (`examples/fx-scene.html`: all three materials and a
  culled straggler, declaratively)
- `(gfx post)` — the post chains, packaged: `make-bloom` /
  `bloom-run!` / `bloom-composite!` (luminance threshold, ping-ponged
  separable gaussian, tonemapped add — `'clamp` or `'reinhard`),
  `make-blur`/`blur-run!` standalone, `make-grade`/`grade-run!`
  (exposure + `'aces`/`'reinhard` tonemap + gamma: point an HDR
  target at it), `make-fxaa`/`fxaa-run!` (one-pass anti-aliasing,
  last in the chain), `make-dof`/`dof-run!` (depth of field: blur
  by distance from the focal plane, over an fx-ssao-style linear
  depth target — `examples/fx-dof.html`), and `post-quad!`/`post-pass!` as the floor for
  custom chains (`examples/fx-bloom.html` is three calls now;
  fx-deferred ends HDR → ACES → FXAA)
- `(gfx mat)` — 3D math for raw-GL scenes: vec3 and column-major mat4
  over flonum vectors (`m4-mul` runs 3.5× faster through the wasm
  SIMD primitives once `fx-init!` hands it 128 bytes of scratch —
  each result column is one f32x4 scale and three axpys).  The
  `m4s` family refunds the copy tax entirely: a matrix as a staging
  ADDRESS, `m4s-mul!` chains in pure SIMD with no boxed reads in or
  vector out, `m4s-trs!` composes a whole T·Ry·Rx·Rz·S in closed
  form, and `cmd-uniform-matrix4s!` uploads by carrying the address
  in three words (the replayer reads the floats in place).  The v3
  family has destructive spellings (`v3-add!` ... `v3-normalize!`)
  whose results land in a caller-owned vector, so per-frame loops
  allocate their vectors once — `(gfx collide)`'s character step and
  the scene cull run on them.  With `m4-perspective` / `m4-ortho` /
  `m4-look-at` / rotations / `m4-inverse` and its own range-reduced
  trig, so it is pure Scheme all
  the way down and verifies headlessly; `m4-frustum-planes` +
  `sphere-in-frustum?` (with the unboxed `sphere-in-frustum-xyz?`
  and `mesh-bounds`) cull what the camera
  cannot see, and `fx-uniform!` feeds a mat4
  straight through the command buffer
  (`examples/fx-cube.html`: an indexed, depth-tested cube, no
  Three.js; `examples/fx-pick.html`: `m4-unproject` casts the cursor
  as a ray and `ray-aabb` answers what it hit)
- `(gfx mesh)` — parametric geometry in pure Scheme: plane, box,
  sphere, cylinder, torus — and `mesh-heightmap`, terrain from any
  pure height function with its own central-difference normals
  (`examples/fx-terrain.html`: altitude-ramped hills under
  exponential fog) — as interleaved positions + normals with u16
  indices, generated headlessly-verifiably and laid into the staging
  memory by `mesh-write!` — or by `mesh-write-f16!` as IEEE
  half-floats (encoded in pure Scheme off the f32 bit pattern,
  round-to-nearest): half the vertex bandwidth and memory, paired
  with `cmd-vertex-attrib-h!`'s HALF_FLOAT wiring, and positions or
  unit normals lose nothing a screen shows;
  `mesh-optimize!` reorders any mesh's triangles for the GPU's
  post-transform vertex cache (Forsyth's linear-time greedy: a
  simulated LRU scores recency, low valence boosts stragglers) and
  `mesh-acmr` measures the result headlessly — shuffled soup drops
  from over 1.0 misses per triangle back under 0.75 — and then
  `mesh-remap!` renumbers the vertices into first-use order so the
  vertex buffer is fetched front to back;
  `mesh-lit-vs`/`-fs` ship the standard
  directional-light program as composable glsl forms
  (`examples/fx-mesh.html`: a lit scene — ground, torus, sphere —
  raw WebGL).  Every generator also carries parametric texture
  coordinates: `mesh-write-uv!` interleaves them and
  `mesh-tex-vs`/`-fs` sample under the same light
  (`examples/fx-tex.html`: a checkerboard painted on a 2d canvas,
  no asset files).  `mesh-tangents` derives a tangent frame from the
  uv gradients and `mesh-normal-vs`/`-fs` light through a
  tangent-space normal map (`examples/fx-normalmap.html`: the bumps
  are procedural bytes fed to `gl-texture-data!`, and an illusion).
  `mesh-pbr-vs`/`-fs` are Cook-Torrance GGX with Karis' split-sum
  ambient — a prefiltered environment plus the BRDF lookup table
  from `(gfx ibl)` (`examples/fx-pbr.html`: the metallic × roughness
  calibration grid)
- `(gfx ibl)` — the light-probe bake, on the GPU: `ibl-prefilter!`
  renders a fresh cube map whose mip chain is the source environment
  convolved with GGX at rising roughness (one pass per face × level,
  through `gl-cube-face-fb!`), and `ibl-brdf-lut!` bakes the
  split-sum integration into a 2D scale/bias table — both with
  Fibonacci-spiral importance sampling, so the shaders stay ESSL 1.00
- `(gfx gpu)` — a WebGPU backend: the same command-buffer
  architecture as `(gfx gl)` — resources in a slot table, one bridge
  call per frame replaying staged words, here into a render pass and
  one `queue.submit` — with pipelines from WGSL source (depth test
  on, over a depth buffer that comes up with the canvas), vertex /
  u16-index / uniform buffers, and bind groups: the shader's whole
  uniform struct is one buffer written by one upload per frame,
  because WebGPU has no `uniform1f`
  (`examples/gpu-particles.html`: the fountain, no WebGL;
  `examples/gpu-torus.html`: lit indexed 3D through a
  `@group(0) @binding(0)` matrix struct).  The header documents the mapping.  `(gfx wgsl)`
  closes the shader gap: `wgsl->string` renders the SAME s-expression
  forms `(gfx glsl)` renders — merged uniform struct, VOut varyings,
  entry-point rewrites — and `wgsl-layout` derives the pipeline's
  vertex formats from the same attribute declarations, so one shader
  source now speaks ESSL 1.00, ESSL 3.00 and WGSL — `sampler2D`
  uniforms included: they split into sampler + texture binding
  pairs (`gpu-texture!`/`gpu-sampler!`/`gpu-texgroup!` on the other
  side; `examples/gpu-tex.html`: a checkerboard box, shader from
  forms, texture from staging bytes).  `gpu-bundle!` freezes
  encoded draws into a render bundle — recorded once, the browser
  replays a whole static scene with no decode at all, so a frame is
  clear + uniforms + `gpu-execute!` (gpu-torus does this).  Compute
  passes close the loop: `gpu-dispatch!` runs a `@compute` shader
  over a storage buffer that doubles as the render pass's instance
  stream
  (`examples/gpu-compute.html`: 100,000 particles whose physics
  never touches the CPU — 16 bytes of uniforms per frame), and
  GPU-driven draws close it twice: a compute pass culls every
  instance against the frustum, compacts survivors with one
  `atomicAdd` and writes the draw's own argument buffer
  (`gpu-indirect!`), which `gpu-draw-indexed-indirect!` then draws
  (`examples/gpu-cull.html`: 100,000 boxes the CPU never inspects)
  — and the cull sees through walls' worth of nothing: `gpu-hzb!`
  reduces the frame's own depth buffer into a max-mip pyramid
  (compute, one dispatch per level) after `gpu-end-pass!` closes
  the occluder pass, and the kernel rejects any sphere whose
  nearest point is farther than everything already drawn over its
  screen footprint (`examples/gpu-hzb.html`: 30,000 boxes behind
  three walls; open with #nocull — the image is pixel-identical,
  which is the whole correctness claim of occlusion culling).
  `gpu-gpu-timer!`/`gpu-gpu-ms` are the backend's frame timer —
  timestamp queries stamp the render pass when the adapter offers
  the feature, mirroring `gl-gpu-timer!` on the other side
- `(gfx sgpu)` — the declarative scene on the WebGPU backend: the
  same `sgl` notation (camera, light, nested groups, signal holes),
  culled and drawn entirely GPU-side — every mesh joins a geometry
  group (WebGPU has no cheap per-draw uniforms, so a single is a
  group of one), instances live in storage buffers as matrix +
  color + bounding sphere, a compute kernel culls and compacts
  survivors into the instance stream, and one `drawIndexedIndirect`
  per group draws exactly the visible count.  The CPU recomposes
  only matrices whose signals moved and never inspects an instance
  (`examples/sgpu-scene.html`: a swinging assembly over a textured
  floor).  Lit solid color and `(texture slot)` for now — probes,
  lod and welding remain the GL backend's
- `(gfx xr)` — WebXR over the same command buffer: `xr-start!`
  swaps the pump for the session's rAF, each eye's projection and
  view arrive from the `XRPose` straight into staging memory
  (`xr-eye-vp` hands them back as `(gfx mat)` m4s), and the frame
  draws once per eye into the session's framebuffer — the command
  buffer and every shader stay untouched
  (`examples/xr-room.html`: one scene, a desktop orbit and an
  Enter&nbsp;VR button; the XR path verifies against a mock session
  headlessly)
- `(gfx collide)` — collision tests and raycasts for 3D games:
  sphere/AABB/capsule overlaps (capsule–capsule rides the classic
  segment–segment distance), ray against sphere, box, plane,
  triangle and whole meshes (Möller–Trumbore), and
  `sphere-aabb-push` — the shortest exit vector, so wall sliding is
  one add.  `sweep-sphere-aabb` answers where along a motion the
  first contact lands (Minkowski-inflated slabs, so fast movers
  cannot tunnel) with the contact normal, and `move-and-slide`
  packages the character-controller loop over it: advance to
  contact, shed the into-the-wall component, continue — walls
  slide, corners stop.  `make-character`/`character-move!` finish
  the job — gravity, landing and `character-jump!` over the slide —
  and `make-aabb-grid`/`grid-near` are the broadphase: static boxes
  hash into xz cells so each step sweeps a handful, not the level.
  Pure arithmetic, verifies headlessly
- `(gfx ktx)` — compressed textures without the C++ transcoder: the
  KTX2 container and the Basis Universal ETC1S/BasisLZ decoder,
  written from the Khronos specifications — canonical Huffman
  codebooks, DPCM endpoint palettes, the selector history buffer,
  the whole slice state machine — in pure Scheme.  Transcode any
  level to what the GPU speaks: ETC1 (a bit-identical block
  repack), BC1 (the table-free path), or RGBA8, the fallback that
  needs no extension; `gl-compressed-family` answers which, and
  `gl-compressed-level!` uploads the mip chain straight from
  staging.  `ktx-stream!` exploits the container's layout (level
  data sits smallest mip first) to stream: three ranged requests --
  a 1KB head, everything below level 0, the rest -- with
  `TEXTURE_BASE_LEVEL` walking down as levels land, so the texture
  is usable from its small mips while the big one is still in
  flight (servers without Range support degrade to one load).
  The decoder is verified byte-for-byte against the
  reference transcoder's unpack (the RGBA goldens ride in the test),
  a full mip chain transcodes in single-digit milliseconds, and it
  DCEs down to a few KB inside a module — where the official C++
  transcoder is a 300–700KB wasm all its own
  (`examples/fx-ktx.html`)
- `(gfx gltf)` — real 3D assets: GLB files parse with the binary
  chunk in staging memory (the wasm f32 loads are the float decoder).
  Geometry, node transforms, base colors, metallic/roughness
  factors, embedded textures
  (`gltf-load-textures!`), skins and animations all load: 
  `gltf-animate!` samples the channels each frame (looping, nlerp
  rotations), `gltf-animate-blend!` crossfades two clips,
  `anim-machine` packages the pattern every character repeats —
  named states over clips, `anim-goto!` transitions that fade over
  a per-transition time while both clocks keep running — and
  `gltf-skin-vs` blends four weighted joints per
  vertex from one mat4-array upload.  The skeleton composes without
  a boxed matrix anywhere: every node's local is `m4s-tqs!` in
  closed form, parent chains multiply in SIMD parents-first into a
  resident staging arena, the inverse binds were staged once at
  parse, and `gltf-joint-palette!` hands back the palette's address
  — three command words upload the whole skeleton, read in place
  (`examples/fx-gltf.html`: the lit Box; `fx-gltf-tex.html`: a
  textured asset; `fx-fox.html`: the rigged Fox — Survey / Walk /
  Run crossfade on keys 1-3)

## Audio

In `lib/aud/`:

- `(aud sfx)` — game audio over WebAudio: `beep!` is an oscillator
  with a click-free fade (no asset files needed), `load-sound!` runs
  the fetch/decode chain, `play!`/`loop-sound!` wire
  buffer→gain→destination; breakout's blips are the dogfood

## Usage

Node 22+ (or any Wasm GC engine) is all you need: the compiler ships
as `goeteia.wasm`, itself a Wasm GC module.

```
$ npm install goeteia
$ npx goeteia compile program.ss program.wasm   # compile to a wasm module
$ npx goeteia run program.wasm                   # run a compiled module
$ npx goeteia program.ss                         # compile and run in one step
$ npx goeteia repl                               # interactive session
$ npx goeteia dev [port]                          # live-reload dev server (cwd)
```

Without installing, the same steps run straight from a checkout:

```
$ node rt/compile.mjs goeteia.wasm program.ss program.wasm
$ node rt/run.mjs program.wasm
```

A program is a sequence of top-level definitions and expressions; the
value of the last expression is printed.

```scheme
(define (fact n)
  (if (zero? n) 1 (* n (fact (- n 1)))))
(fact 20)          ; prints 2432902008176640000
```

### Web projects

`npx goeteia dev` serves the current directory, watches its Scheme/JS/CSS
sources, and on every save runs the project's `./build.sh` (which
recompiles any changed page module) before pushing a live reload to
every open tab. Edit a `.ss`, save, and the page re-renders.

A module can also run its whole render loop OFF the main thread:
`loadGoeteiaWorker(url, canvas)` transfers the canvas to a Worker
(OffscreenCanvas), forwards keys and pointer events as messages, and
`rt/worker.mjs` re-dispatches them to the module's listeners — the
program finds its canvas at `(js-get (js-global) "__goeteia_canvas")`
instead of the DOM, and everything else (fx-init!, fx-loop!, input)
runs unchanged (`examples/fx-worker.html`: jam the main thread for a
second, the animation doesn't drop a frame).

## Self-hosting

`goeteia.wasm` is Goeteia compiled by Goeteia.  After editing
the compiler:

```
$ ./rebuild.sh      # snapshot compiles the source; the result
                    # recompiles it; byte-equal -> snapshot replaced
```

With [Chez Scheme](https://cisco.github.io/ChezScheme/) installed,
`./build-self.sh` runs the stronger cross-host check: the Chez-hosted
compiler and the self-hosted compiler must produce byte-identical
output from the same source — two independent hosts agreeing on every
byte.  Chez is optional: it's the from-source bootstrap path and the
independent verifier, not a dependency (`./bin/goeteiac` uses it as a
host if you have it).

## Playground

`playground.html` is the browser playground — the self-hosted
compiler running as a Wasm GC module, no server-side anything. Serve
the repo root statically and open it:

```
$ npx goeteia dev        # or: python3 -m http.server
```

then visit `http://localhost:8100/playground.html`. It compiles and
runs your Scheme in a Web Worker, entirely in the browser.

## Tests

```
$ ./run-tests.sh
```

Each file in `test/` declares its expected output in its first line
and runs through both the Chez-hosted and the self-hosted compiler.
Every test also checks that the two hosts emit byte-identical
modules, so the cross-host fixpoint is guarded per test, not just for
the compiler itself.  `bench/` holds standalone microbenchmarks
(`bench/perf.ss` covers the web stack's per-frame hot paths).

## Design

Goeteia is an independent implementation written from the R6RS and
WebAssembly specifications.

### Why Wasm GC

Pre-GC Scheme-on-Wasm systems had to keep the heap on the host side
(every pair a JS object, every `car` a wasm→JS call) or roll their own
GC in linear memory.  Wasm GC removes both compromises: the engine's
collector manages our objects, and every primitive operation is a
plain wasm instruction.  The compiled modules need a host only for
I/O, so they run in browsers, Node, and standalone runtimes alike.

### Object representation

The universal value type is `eqref` (all Scheme values support `eq?`,
which compiles to `ref.eq`).

| Scheme value  | representation                                     |
|---------------|----------------------------------------------------|
| fixnum        | `i31ref`, value `n << 1` (30-bit, unboxed)         |
| bignum        | `(struct i32-sign (ref $vector))`, 14-bit limbs; fixnum arithmetic promotes on overflow (bits 30/31 disagree after a tagged add/sub; products checked in i64) |
| flonum        | `(struct f64)`; contagion via prelude generics, IEEE-754 bits for literals computed in pure Scheme so both hosts emit identical bytes |
| ratio         | `(struct eqref eqref)`, canonical (positive denominator, gcd-reduced, denominator 1 collapses); exact `/` returns these |
| complex       | `(struct eqref (mut eqref))` — the mutable slot only distinguishes it from `$ratio` under structural canonicalization; exact zero imaginary collapses |
| character     | `i31ref`, value `(c << 1) | 1`                     |
| boolean, `()`, unspecified | singleton structs held in globals     |
| pair          | `(struct (field mut eqref) (field mut eqref))`     |
| string        | `(array mut i8)`, literals interned as globals     |
| symbol        | `(struct (ref $string))`, interned as globals      |
| closure       | per-arity `(struct (ref $fnN) eqref)`, subtype of an open `$closure` base (which is what `procedure?` tests) |
| vector        | `(array mut eqref)`                                |
| bytevector    | `(struct (mut (ref $string)))` — the mutable field makes it structurally distinct from `$symbol` |
| record        | per-field-count `(struct rtd (mut eqref)*n)` <: an open `$record` base; the rtd slot holds a unique pair, so `point?` is one `ref.test` plus one `ref.eq` |

The fixnum/character tag bit keeps both unboxed and `eq?`-comparable;
`+`, `-`, `remainder` and the comparisons operate directly on the
tagged values.

Console I/O uses `io.write_byte`/`io.read_byte`; file ports add six
more imports (a byte-pushed path, open/read/write/close on fds) with
real implementations in the Node runners and stubs in the browser.
Beyond that, the runtime library
(`display`, `string=?`, ...) is written in goeteia's own Scheme
(`src/prelude.ss`) and compiled into every module, with user
definitions overriding same-named prelude definitions.

Type checks are `ref.test`; field access casts with `ref.cast`.
Booleans are identity-compared against the `$false` singleton, so
truthiness is one `ref.eq`.

### Compiler pipeline

```
source forms
  → expand      (macros: syntax-rules / syntax-case, derived forms)
  → inline      (small once-used helpers β-reduce to let)
  → analyze     (assignment conversion, top-level defines vs. exprs)
  → prune       (dead code elimination: keep only what's reachable)
  → codegen     (per function: expression tree → instruction list)
  → emit        (instruction list → binary module + name section)
```

Every top-level input form carries a `file:line` from the reader
through expansion, so a compile error reports `at file:line
(function)`; the locations feed error messages only, never the
emitted bytes.  The `emit` stage writes a wasm name section, so
browser stack traces and profilers show Scheme function names.

The compiler is written in the subset of Scheme that it compiles.
Chez Scheme hosts it for bootstrapping; the self-hosted build
(`build-self.sh`) compiles the compiler with itself and checks that
the result is a byte-identical fixpoint.

### Ports and exceptions

String ports are plain records; the reader and printers dispatch
through `current-input-port`/`current-output-port`, so
`with-output-to-string`, `number->string` and `string->number` need
no host support (console I/O remains the two byte-stream imports).

`guard`/`raise` ride the same escape-continuation machinery as
call/cc: a guard pushes its continuation on a handler stack, raise
escapes to the nearest one (running dynamic-wind afters on the way),
and an unmatched clause re-raises outward.  `error` and `errorf`
raise a condition record (`error?`, `condition-who/-message/
-irritants`); an unhandled exception prints and traps, so compiler
errors read exactly as before but user code can guard them.

### The JS bridge

Host references live in `$jsref = (struct externref)`, making JS
objects first-class Scheme values.  Twenty `js.*` imports carry
property access, calls, constructors, string/number conversion, and
the callback protocol (names and strings cross byte by byte, call
arguments through a push protocol).  Scheme closures convert to callable JS functions: the
host holds the closure as an opaque eqref and invokes the exported
`$jscb` when JS calls it, with arguments and the return value moving
through dedicated imports -- so `addEventListener` takes a lambda.
`(web js)` wraps the primitives; `(web dom)` adds DOM sugar; a page
needs one `<script type="module">` loading `rt/web.mjs`.  See
`examples/counter.html` -- a page scripted entirely in Goeteia.

### Libraries

A library is one `(library (name parts) (export ...) (import ...)
defs...)` form in `name/parts.ss`, found relative to the importing
file, its `lib/`, or the repo `lib/`.  The drivers inline imports
(dependencies first, each library once); the expander splices library
bodies -- exports are advisory, and dead code elimination prunes
whatever a program doesn't use.  `(rnrs ...)` names are satisfied by
the prelude.  `rename` import specs create top-level aliases; `only`/`except` are
advisory in the flat-splice model (dead code elimination prunes the
unused anyway).

### Program shape

A goeteia program is a sequence of top-level definitions and
expressions.  Expressions run in order; the value of the last one is
the program's result, exported as `main`.

### Calling convention

Top-level functions are wasm functions of type `(eqref^n) → eqref`
called directly (`call`/`return_call`); a variadic definition takes
its rest parameter as one final list-valued argument, consed up at
the call site.

Every closure struct carries **two entry points**:

* field 0 — the fast entry, typed per arity: `$fnN = (func (ref
  $closN) eqref^n → eqref)`, invoked with `call_ref` after a
  `ref.test`-guarded cast;
* field 1 — the generic entry `$fnG = (func (ref $closbase) eqref →
  eqref)`, which takes the arguments as a list.

A call site with a statically known argument count tests the callee
against `$closN`: on a hit it uses the fast entry with the arguments
on the wasm stack (no allocation); otherwise it conses the arguments
and calls the generic entry.  Fixed-arity closures share one generic
adapter per arity (unpack the list, forward to the fast entry);
variadic closures' body *is* their generic entry.  `apply` always
targets the generic entry, so `(apply f a b lst)` is just two conses.
Tail calls use `return_call_ref` on either path.

### Compressed textures

`(gfx ktx)` transcodes Basis Universal ETC1S/BasisLZ inside a KTX2
container, and it is written from the Khronos bitstream specification
rather than vendoring the reference C++ transcoder — that transcoder
is a 300–700KB wasm of its own, while a decoder written in the subset
goeteia already compiles rides the DCE like any other library and
falls to a few KB when a module uses only the target it needs.

The bitstream is a chain of LSB-first bit fields, and the reader keeps
its accumulator in a fixnum: refill caps at 30 live bits (an `i31`
holds no more) and no field is wider than 16, so the whole reader is
fixnum arithmetic with no bignum ever touched.  Every Huffman table is
canonical — codes assigned by (length, symbol) — and the decode walks
lengths one bit at a time, comparing against the first code at each
length; the encoder emits the codes MSB-first while the reader is
LSB-first, and the two reversals cancel, so no bit-reversal table
exists on our side at all.

The endpoint palette is DPCM: each of R, G, B is a delta from the
predecessor through one of three Huffman models split by the
predecessor's magnitude (`p ≤ 9`, `≤ 21`, else), with mod-32/mod-8
wrap, and the intensity index its own model.  Selectors ride a history
buffer with an approximate move-to-front — a hit doesn't shift the
whole buffer, it swaps the entry with the one halfway toward the front
— plus a run-length escape.  Endpoints across the image are predicted
in 2x2 block groups: a two-bit code per block, read at the group's
even/even corner and its top nibble saved to restore on the odd row,
says whether the block reuses the left, the up, or the upper-left
endpoint or reads a fresh delta — a small state machine walking the
grid.

Three targets come off the reconstructed (endpoint, selector) blocks:
ETC1, a bit-identical repack of the ETC1S block into an ETC1 one; BC1,
a table-free path that takes the block's brightest and darkest colors
as the BC1 endpoints (the reference bakes optimal tables; this trades
a little PSNR for carrying none); and RGBA8, the universal fallback
that decodes to plain pixels and needs no GPU extension — and the
one that carries alpha: an RGBA file's alpha is a second grayscale
ETC1S slice, decoded by the same machinery into the A bytes.  The test
carries golden RGBA rows unpacked by the official basisu transcoder
from a real encoder-produced file, and the decode is checked against
them byte-for-byte across every mip level.

### Roadmap

- **M1 (done)**: fixnums, booleans, pairs, arithmetic, comparisons,
  `if`/`let`/`begin`/`quote`, top-level defines with direct (and tail)
  calls, binary emission, Node runner, test harness.
- **M2 (done)**: closures (`lambda` via `call_ref` on typed function
  references, one `(func, struct)` rec group per arity), assignment
  conversion for `set!` (assigned lexicals boxed in pairs), top-level
  variables as mutable globals, derived forms (`and`/`or`/`not`/
  `when`/`unless`/`cond`/`let*`/`letrec`/`letrec*`/named `let`/`do`),
  top-level functions as first-class values (auto-wrapped), tail
  calls through closures via `return_call_ref`.
- **M3 (done)**: strings as GC byte arrays, interned symbols,
  characters (tagged i31), the full set of type predicates,
  `quotient`/`remainder`, and `display`/`newline` through the
  `io.write_byte` import, with the runtime library written in
  goeteia's own Scheme.
- **M4 (done)**: variadic procedures (`(lambda args ...)`, dotted
  formals) via the dual-entry closure convention, `apply`, `values` /
  `call-with-values`, and the list library (`list`, `length`,
  `append`, `reverse`, `map`, `for-each`, `memq`, `assq`, `equal?`).
- **M5 (done)**: `read` written in prelude Scheme over a second host
  import `io.read_byte` (with one byte of pushback for peeking),
  `write`, `list->string`/`string->list`/`string-set!`, and runtime
  symbol interning: `string->symbol` seeds its table lazily from a
  compiler-generated function that lists the module's interned symbol
  globals, so symbols built at runtime are `eq?` to compile-time
  literals.
- **M6 (done)**: hygienic macros.  `define-syntax` takes
  `syntax-rules` or a `(lambda (x) ...)` transformer using
  `syntax-case` (patterns with `_`, literals, nested ellipses, tail
  patterns, `(... ...)` escapes, fenders), `with-syntax`,
  `syntax->datum`, `datum->syntax`, `identifier?`,
  `free-identifier=?`, `bound-identifier=?`, `generate-temporaries`.
  Transformers run in a compile-time interpreter over a Scheme
  subset.  Hygiene is by renaming: template-introduced identifiers
  become fresh gensyms recorded in a mark table, and identifier
  resolution (keywords, variables, literals) falls back through the
  table while `quote`/`syntax->datum` strip it.  Macros may expand
  into `define-syntax`.
- **M7 (done)**: self-hosting.  The compiler is written in the
  subset goeteia compiles.  `src/chez-driver.ss` hosts it under Chez
  (stage0); `src/wasm-driver.ss` appended to `src/compiler.ss` and
  compiled by stage0 yields `goeteia.wasm` (stage1), a wasm
  module that reads Scheme source on its input and emits a wasm
  module on its output.  Stage1 compiling the compiler reproduces
  itself byte-for-byte (`./build-self.sh` verifies the fixpoint), and
  the test suite runs against both stages.

  Self-hosting forced the codegen to be independent of the host's
  evaluation order: argument-, binding- and map-orderings around
  side-effecting codegen (function index allocation, literal
  interning, local slots) are all explicitly sequenced.  It also
  motivated n-ary `+`/`-`/`*` with strict arity checking for the
  other primitives -- a silently dropped argument cost a day of
  index-space debugging.
- **M8 (done)**: compressed textures — `(gfx ktx)`, a Basis Universal
  ETC1S/BasisLZ transcoder written from the Khronos specifications, no
  C++ transcoder vendored.  KTX2 container parse, a fixnum-safe
  LSB-first bit reader, canonical-Huffman codebooks, DPCM endpoint
  palettes, the approximate-move-to-front selector history, and the
  2x2 endpoint-prediction state machine, feeding three transcode
  targets (ETC1 bit-identical repack, table-free BC1, universal
  RGBA8).  Verified byte-for-byte against the reference transcoder's
  unpack, and it DCEs to a few KB where the official transcoder is a
  300–700KB wasm.  See [Compressed textures](#compressed-textures).

## License

MIT.  See LICENSE.
