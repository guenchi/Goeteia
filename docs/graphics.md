# Goeteia Graphics Stack

The rendering and asset code lives in `lib/gfx/`. Every backend, shader
dialect, math routine, and decoder is pure Scheme compiled to Wasm GC —
no C++, no host-side helpers beyond the JS bridge that replays a command
buffer. This guide walks the stack from the two backends up through
declarative scenes and the compressed-asset pipeline.

## Contents

1. [Rendering backends](#1-rendering-backends)
2. [Shaders as s-expressions](#2-shaders-as-s-expressions)
3. [Declarative scenes](#3-declarative-scenes)
4. [Math](#4-math)
5. [The compressed-asset pipeline](#5-the-compressed-asset-pipeline)
6. [Effects and games toolkit](#6-effects-and-games-toolkit)

---

## 1. Rendering backends

Both backends share one architecture: Scheme encodes a frame of API
commands as words into the shared linear (staging) memory, and **one**
bridge call per frame hands the region to a JS replayer that walks the
words and issues the real calls. Resources — programs, buffers, textures
— are JS objects that cannot cross as bytes, so they are created once at
init over the normal FFI and kept in a slot table; commands refer to
slot numbers. Vertex data lives in the same staging memory, so uploads
are zero-copy.

### `(gfx gl)` — WebGL command buffer

The context is WebGL 2 with a WebGL 1 fallback. The `gl-*!` procedures
create resources; the `cmd-*!` procedures encode a frame between
`cmd-begin!` and `cmd-flush!` (the one bridge call).

```scheme
(gl-attach! canvas)                      ; once
(gl-program! 0 vs-src fs-src)            ; slot 0, once
(gl-buffer! 1)
(gl-uniform! 2 0 "u_time")
;; ... per frame:
(cmd-begin!)
(cmd-clear! 0.1 0.1 0.15 1.0)
(cmd-use-program! 0)
(cmd-bind-buffer! 1)
(cmd-buffer-data! vertex-base byte-len)  ; from staging memory
(cmd-vertex-attrib! 0 2 0 0)
(cmd-draw-arrays! GL-POINTS 0 n)
(cmd-flush!)                             ; the one bridge call
```

Beyond the basics the module exports offscreen render targets
(`gl-target!`, `gl-target-hdr!`, `gl-target-msaa!`, `gl-target-mrt!`,
`gl-cube-target!` with `cmd-bind-target!` / `cmd-resolve!`), indexed
draws (`cmd-bind-index!`, `cmd-index-data!`, `cmd-draw-elements!`, plus
the 32-bit variants), instancing (`cmd-attrib-divisor!`,
`cmd-draw-elements-instanced!`, `cmd-uniform-matrices!`), cube maps
(`gl-cubemap!`, `cmd-bind-cubemap!`), texture arrays
(`gl-texture-array!`, `cmd-bind-texture-array!`), UBOs (`gl-ubo!`,
`gl-uniform-block!`, `cmd-ubo-data!`), transform feedback
(`gl-tf-program!`, `cmd-tf-begin!` / `cmd-tf-end!`), half-float vertex
attributes (`cmd-vertex-attrib-h!`), and a GPU frame timer
(`gl-gpu-timer!` / `gl-gpu-ms`). The `cmd-pos` and `cmd-draws` counters
make instrumentation free — the frame's byte size is the write cursor
and draws are counted as they encode (see `(gfx stats)`). Example:
`examples/gl-particles.html` (10,000 particles, one call per frame).

### `(gfx gpu)` — WebGPU

The same command-buffer architecture carried to WebGPU: resources in a
slot table, one bridge call per frame replaying staged words into a
render pass and one `queue.submit`. Attach is async (the adapter/device
handshake calls you back), and a `depth24plus` buffer sized to the
canvas comes up with it.

```scheme
(gpu-attach! canvas (lambda () ...ready...))
(gpu-pipeline! 0 wgsl 24 "float32x3,float32x3")
(gpu-buffer! 1 vbytes) (gpu-index! 2 ibytes)
(gpu-uniforms! 3 64) (gpu-bindgroup! 4 0 3)
;; ... per frame:
(gpu-begin!)
(gpu-clear! 0.02 0.02 0.05 1.0)
(gpu-use-pipeline! 0) (gpu-set-group! 4)
(gpu-bind-vbuf! 1) (gpu-bind-ibuf! 2)
(gpu-buffer-data! 3 ubase 64)            ; the whole uniform struct, one write
(gpu-draw-indexed! icount)
(gpu-flush!)                             ; one submit
```

WebGPU has no per-name uniforms, so the shader's entire uniform struct
is one buffer written by a single `gpu-buffer-data!` and bound at
`@group(0) @binding(0)`. Additional capabilities: textures and samplers
(`gpu-texture!`, `gpu-sampler!`, `gpu-texgroup!`), render bundles
(`gpu-bundle!` / `gpu-execute!` — a static scene recorded once, replayed
with no decode), compute passes (`gpu-dispatch!`, `gpu-storage!` — a
storage buffer doubling as the render pass's instance stream), GPU-driven
indirect draws (`gpu-indirect!`, `gpu-draw-indexed-indirect!`), an
HZB occlusion pyramid (`gpu-hzb-init!`, `gpu-end-pass!`, `gpu-hzb!`),
and the frame timer (`gpu-gpu-timer!` / `gpu-gpu-ms`). Examples:
`examples/gpu-torus.html`, `examples/gpu-compute.html` (100,000 particles
on the GPU), `examples/gpu-cull.html`, `examples/gpu-hzb.html`.

A page drives one backend or the other, not both at once.

## 2. Shaders as s-expressions

Both backends consume the *same* shader forms. `(gfx glsl)` renders a
shader form list to GLSL; `(gfx wgsl)` renders the same forms to WGSL.
One source of truth, three dialects (ESSL 1.00, ESSL 3.00, WGSL).

### `(gfx glsl)`

`glsl->string` is a pure function from a form list to a GLSL string — the
`(web css)` of shaders — so shaders compose with `append`, `map`, and
helper functions, and verify headlessly.

```scheme
(glsl->string
  '((attribute vec2 p)
    (uniform float u_time)
    (define (main) void
      (local float w (+ (* p.x (fl 0 50)) u_time))
      (set! gl_Position (vec4 p (fl 0) (fl 1)))
      (set! gl_PointSize (fl 2)))))
```

Top-level forms: `(attribute T name)`, `(uniform T name)`,
`(varying T name)`, `(precision P T)`, `(out loc T name)` (an ESSL 3.00
MRT output), and `(define (name (T arg) ...) RET stmt ...)`. Statements
include `local`, `set!`, `return`, `if` / `if-else`, `for`, and
`discard`. In expressions, symbols pass through verbatim (`p`,
`gl_Position`, `v.xy`); exact integers are themselves; `(fl W [F])` is a
float literal with the fraction in hundredths (`(fl 2)` → `"2.0"`,
`(fl 0 50)` → `"0.5"`) so there are no Scheme flonums and no printer
noise; `+ - * /` are infix and `< > <= >= ==` compare; anything else is
a function call. `glsl300-vs->string` / `glsl300-fs->string` emit
`#version 300 es`, where `uniform-block` becomes a std140 block and
`out` forms declare pinned MRT outputs. `glsl-attributes`,
`glsl-uniforms`, and `glsl-varyings` read the interface back out of the
forms — how `(gfx fx)` wires programs automatically.

### `(gfx wgsl)`

`wgsl->string` takes the vertex and fragment form lists **together**,
because WebGPU wants one module:

```scheme
(wgsl->string vs-forms fs-forms)   ; -> "struct U {...} ... fn vs..."
(wgsl-layout vs-forms)             ; -> (stride . "float32x3,...") for gpu-pipeline!
```

The two stages' uniforms merge into one struct at `@group(0) @binding(0)`;
varyings become the `VOut` struct the vertex stage returns and the
fragment stage receives; `gl_Position` / `gl_FragColor` / `gl_FragCoord`
respell themselves; and a `sampler2D` uniform splits into a sampler +
texture binding pair (matching `gpu-texgroup!` on the other side).
`wgsl-layout` derives the pipeline's vertex formats from the same
attribute declarations. Two spelling rules WGSL forces: constructors do
not truncate (go through a `local` and swizzle instead of
`(vec3 some-vec4)`), and order uniform members mat4 / vec4 / vec3+pad /
f32 for the std140-like alignment. `examples/gpu-tex.html` runs a shader
from forms with a texture from staging bytes.

## 3. Declarative scenes

### `(gfx scene)` — `sgl`, raw-GL

`sgl` is to the GL stack what `sx` is to the DOM. The template splits at
expansion time: geometry from `(gfx mesh)` builds and uploads once, and
each unquoted attribute becomes a hole whose effect copies its signal's
value into the node — so a frame is pure arithmetic over current fields,
and only changed values move.

```scheme
(define spin (signal 0.0))
(define bob  (signal 0.4))

(define sc
  (sgl (camera (@ (fov 0.9) (position 0.0 3.5 9.0) (look-at 0.0 0.5 0.0)
                  (near 0.1) (far 40.0)))
       (light (@ (direction 0.5 0.8 0.4) (ambient 0.25)))
       (probe (@ (sky ,env) (lut ,lut) (mips 3)))
       (mesh (@ (geometry (plane 14.0 14.0))
                (position 0.0 -1.6 0.0)
                (texture ,tex)))
       (mesh (@ (geometry (torus 1.6 0.55))
                (position -1.8 0.6 0.0)
                (rotation-y ,(signal-ref spin))
                (color 0.95 0.45 0.35)))
       (mesh (@ (geometry (sphere 1.0))
                (position-x 2.2)
                (position-y ,(signal-ref bob))
                (color 0.85 0.88 0.92)
                (metallic 1.0) (roughness 0.15)))
       ;; alpha < 1 -> the translucent pass, drawn last, back to front
       (mesh (@ (geometry (box 3.0 2.4 0.1))
                (position 0.0 1.2 3.2)
                (color 0.5 0.75 0.95 0.35)))))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.05 0.06 0.10 1.0)
   (signal-set! spin t)
   (signal-set! bob (fl+ 0.4 (fl* 0.8 (flsin (fl* 1.5 t)))))
   (sgl-draw! sc)))
```

Tags are `camera`, `light`, `probe` (the `(gfx ibl)` pair PBR meshes
reflect), `group` (children inherit the parent transform, so one signal
swings a whole assembly), `lod`, and `mesh`. Geometry specs are the
`(gfx mesh)` generators — `(plane w d)`, `(box w h d)`,
`(sphere r [segs rings])`, `(cylinder r h [segs])`,
`(torus R r [segs rings])` — or a lone unquote yielding a `(gfx mesh)`
mesh. `$sgl-build` and `sgl-scene?` round out the exports; `sgl-draw!`
renders a frame.

What the scene does with those declarations:

- **Materials** are declarative per mesh: the default is
  `mesh-lit-vs`/`-fs` (one directional light, ambient floor, solid
  color); `(texture slot)` switches to the UV program with the color
  multiplied in; `(metallic m)` or `(roughness r)` switch to PBR against
  the scene's `probe`.
- **Culling** every frame: a mesh whose bounding sphere (`mesh-bounds`,
  scaled and placed by its fields) falls outside the camera frustum
  contributes nothing, uniforms included. The cull runs four spheres at
  a time — centers and radii SoA in staging, each frustum plane testing
  all four in five SIMD instructions.
- **Instancing**: meshes with the same literal geometry share one upload
  and draw as ONE instanced call. Each visible instance's model matrix
  composes in closed form (`m4s-trs!` / `m4s-mul!`, SIMD, no boxed
  matrix) straight into the instance buffer with its color beside it;
  culled instances simply don't join the buffer.
- **Static welding**: same-color lit meshes of *different* geometry whose
  transforms no signal drives (a zero transform generation proves it)
  bake their model matrices into fresh vertex data at build and draw as
  ONE mesh under one bounding sphere.
- **LOD**: `(lod (@ (switch d1 d2 ...)) mesh1 mesh2 ...)` holds detail
  levels of one thing; the eye's distance picks which child draws.
- **Signal-driven transforms**: matrices cache against a transform
  generation the signals bump. A fully static mesh composes its model
  matrix, world center, and radius exactly once; a frame recomputes only
  what moved.
- **Translucency**: a mesh whose color alpha is below one skips the
  opaque pass and joins a final blended pass drawn back to front with
  depth writes off, so glass reads correctly through glass.
- Frame globals (view-projection, light, ambient, eye) live in one
  std140 Env block every scene program reads from binding 0: 96 bytes
  uploaded once per frame.

Example: `examples/fx-scene.html` (all three materials, a pane of glass,
and a culled straggler).

### `(gfx sgpu)` — `sgl-gpu`, GPU-driven

The same `sgl` notation, culled and drawn entirely GPU-side. Every mesh
joins a geometry group (WebGPU has no cheap per-draw uniforms, so a
"single" is a group of one); each group's instances live in a storage
buffer as matrix + color + bounding sphere; a **compute kernel** culls
them against the frustum and compacts survivors straight into the render
pass's instance stream; and one `drawIndexedIndirect` per group draws
exactly the visible count. The CPU recomposes only matrices whose signals
moved and never inspects an instance.

```scheme
(define angle (signal 0.0))

(define sc
  (sgl-gpu
   (camera (@ (fov 0.9) (position 0.0 6.0 16.0)
              (look-at 0.0 0.0 0.0) (near 0.1) (far 120.0)))
   (light (@ (direction 0.5 0.8 0.4) (ambient 0.3)))
   (group (@ (rotation-y ,(signal-ref angle)))
     (mesh (@ (geometry (torus 2.0 0.6 24 16))
              (position 0.0 1.5 0.0) (color 0.9 0.5 0.3)))
     (mesh (@ (geometry (box 1.2 1.2 1.2))
              (position 4.0 1.5 0.0) (color 0.4 0.7 0.9))))
   (mesh (@ (geometry (plane 40.0 40.0))
            (color 1.0 1.0 1.0) (texture 40)))
   ;; alpha < 1 -> the src-over blend pipeline, depth writes off, last
   (mesh (@ (geometry (box 6.0 4.0 0.2))
            (position 0.0 3.0 6.0) (color 0.5 0.75 0.95 0.35)))))

(gpu-attach!
 (get-element-by-id "c")
 (lambda ()
   (gpu-texture! 40 64 64)
   (gpu-texture-data! 40 check-base 64 64)
   (sgpu-init! sc (get-element-by-id "c"))
   (fx-ticks!
    (lambda (t dt)
      (signal-set! angle (fl* 0.7 t))
      (gpu-begin!)
      (gpu-clear! 0.04 0.05 0.09 1.0)
      (sgpu-draw! sc)
      (gpu-flush!)))))
```

Exports: `sgl-gpu`, `$sgpu-build`, `sgpu-init!`, `sgpu-draw!`,
`sgpu-scene?`. Materials are lit solid color, `(texture slot)`, and
translucency (alpha below one draws last on a src-over blend pipeline
with depth writes off). Grouping keys on geometry AND texture. PBR
probes, `lod` containers, static welding, and HZB occlusion remain the GL
backend's for now. Example: `examples/sgpu-scene.html`.

## 4. Math

`(gfx mat)` is vec3 and column-major mat4 over plain flonum vectors —
pure, verifies headlessly, with its own range-reduced trig (`flsin`,
`flcos`, `fltan`) so both compiler hosts emit identical bytes.

```scheme
(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define view (m4-look-at (v3 0 0 6) (v3 0 0 0) (v3 0 1 0)))
(fx-uniform! p 'u_mvp (m4-mul proj (m4-mul view (m4-rotate-y t))))
```

A mat4 is a 16-element vector, column-major (what `uniformMatrix4fv`
expects). `m4-mul` runs ~3.5× faster through the Wasm SIMD primitives
once `fx-init!` hands it scratch: each result column is one
`%f32x4-scale!` plus three `%f32x4-axpy!`. Constructors and camera
matrices (`m4-perspective`, `m4-ortho`, `m4-look-at`, `m4-rotate-x/-y/-z`,
`m4-translate`, `m4-scale`, `m4-from-quat`, `m4-inverse`,
`m4-unproject`) coerce their arguments; the operations assume flonums,
being the per-frame hot path.

The **`m4s` family** refunds the copy tax entirely. A matrix is a staging
*address*, not a boxed vector:

- `m4s-mul!` chains matrices in pure SIMD with no boxed read in or vector
  out.
- `m4s-trs!` composes a whole T·Ry·Rx·Rz·S in closed form;
  `m4s-tqs!` composes T·quat·S (the glTF skeleton path).
- `m4s-write!` / `m4s-read` / `m4s-identity!` move between addresses and
  boxed vectors when needed.
- `cmd-uniform-matrix4s!` (in `(gfx gl)`) uploads by carrying the address
  in three words — the replayer reads the floats in place.

This is the zero-boxing composition the scene backends use: instance
matrices, welded transforms, and joint palettes all compose into staging
memory with no allocation. The `v3-*!` destructive spellings (`v3-add!`
… `v3-normalize!`) land results in a caller-owned vector so per-frame
loops allocate once. Culling helpers: `m4-frustum-planes`,
`sphere-in-frustum?`, and the unboxed `sphere-in-frustum-xyz?`.

## 5. The compressed-asset pipeline

The highlight of the stack. Every decoder is written **from spec in pure
Scheme, zero C++**, each **golden-verified byte-for-byte** against its
reference tool, and each **DCEs to a few KB** inside a module — where the
official C++ equivalents are hundreds of KB of Wasm all their own.

### `(gfx gltf)` — GLB assets

GLB (binary glTF 2.0) files land in staging memory; the JSON chunk parses
through `(web json)` and accessors read f32/u16 straight out of the
binary chunk — the Wasm float loads *are* the decoder, no float decoding
pass.

```scheme
(gltf-fetch! "duck.glb" (lambda (g) (set! duck g)))   ; browser: fetch + parse
;; ...
(define p (fx-program! mesh-lit-vs mesh-lit-fs))
(fx-loop! (lambda (t dt)
            ;; ...
            (gltf-draw! g p vp)))                       ; all primitives, lit
```

What loads: every primitive's POSITION (+ NORMAL, or +y when absent),
u8/u16/u32 indices, node TRS/matrix transforms accumulated through the
scene graph, `baseColorFactor` and metallic/roughness factors, embedded
textures (`gltf-load-textures!`), skins, and animations. Untextured
primitives come out in `mesh-lit-vs`'s 24-byte layout, textured ones at
32 bytes, skinned at 64 for `gltf-skin-vs` (four weighted joints per
vertex from one mat4-array upload). Animation is sampled and blended:
`gltf-animate!` samples channels each frame (looping, nlerp rotations),
`gltf-animate-blend!` crossfades two clips, `gltf-weights!` /
`gprim-morph` drive morph targets, and `anim-machine` / `anim-goto!` /
`anim-update!` package named states over clips with per-transition fades.
The skeleton composes without a boxed matrix anywhere: each node's local
is `m4s-tqs!` in closed form, parent chains multiply in SIMD
parents-first into a resident staging arena, and `gltf-joint-palette!`
hands back the palette's address for a three-word upload. `gltf-parse`
works on any GLB bytes already in staging, so parsing verifies headlessly
(`test/gltf.ss`). Examples: `examples/fx-gltf.html` (lit Box),
`fx-gltf-tex.html` (textured), `fx-fox.html` (the rigged Fox, Survey /
Walk / Run crossfade on keys 1-3).

### `(gfx ktx)` — KTX2 decode/transcode

The KTX2 container plus the Basis Universal ETC1S/BasisLZ decoder and the
UASTC path, all from the Khronos specifications.

```scheme
(define k (ktx-parse base len))
(ktx-width k) (ktx-height k) (ktx-level-count k)
(ktx-transcode! k level dst 'rgba)      ; ETC1S -> 'etc1 | 'bc1 | 'rgba
(ktx-uastc-level! k level dst)          ; UASTC -> RGBA
```

The ETC1S decoder reconstructs canonical Huffman codebooks, DPCM endpoint
palettes, the selector history buffer, and the whole slice state machine
in Scheme, then transcodes any level to what the GPU speaks: **ETC1** (a
bit-identical block repack), **BC1** (the table-free path), or **RGBA8**
(the universal fallback needing no extension, and the one carrying alpha
— an RGBA file's alpha is a second grayscale ETC1S slice).
`gl-compressed-family` answers which target the context supports, and
`gl-compressed-level!` uploads the mip chain from staging.
`ktx-stream!` exploits the container layout (smallest mip first) to load
big textures progressively via ranged requests, with `TEXTURE_BASE_LEVEL`
walking down as levels land. UASTC LDR 4x4 blocks (DFD color model 166),
raw or zstd-supercompressed, decode to RGBA through `(gfx zstd)` +
`(gfx uastc)`; `ktx-upload!` picks the path and `ktx-alpha?` reports
alpha. Verified block-for-block against the reference transcoder's unpack
(`test/ktx.ss` for ETC1S, `test/ktx-uastc.ss` for UASTC raw + zstd).
Example: `examples/fx-ktx.html`.

### `(gfx zstd)` — Zstandard, RFC 8878

A single-frame Zstandard decompressor over staging memory, no libzstd:
the frame, all three block types (raw / RLE / compressed), Huffman
literals (direct and FSE-described weights, single- and four-stream), and
the three interleaved FSE sequence streams.

```scheme
(zstd-decode! src slen dst scratch)   ; -> bytes written at dst
```

`scratch` is a spare region (≥ one block's literal size) where decoded
literals stage before the sequence stage interleaves them with
back-references. Two bitstreams live in one decoder: FSE table
descriptions read forward from a byte, Huffman and FSE payloads read
backward from a sentinel bit at the end. KTX2 wraps its UASTC payload in
one zstd frame (supercompressionScheme 2) and this unwraps it. Verified
byte-for-byte against the `zstd` CLI over four inputs — a raw block, RLE
literals, Huffman + FSE, and a large four-stream blob with FSE-described
weights (`test/zstd.ss`).

### `(gfx uastc)` — UASTC LDR 4x4 → RGBA

From the Basis Universal transcoder. A UASTC block is 128 bits of
ASTC-like data: a 7-bit mode code (19 modes) selects 1/2/3 subsets, one
or two weight planes, and RGB / RGBA / LA / solid layout; endpoints and
per-texel weights unpack and interpolate to 16 texels.

```scheme
(uastc-block! src dst)          ; one 16-byte block -> 64 bytes RGBA
(uastc-decode! src dst w h)     ; a whole level
```

UASTC packs its BISE trits/quints as plain base-3/5 bundles (its
simplification over ASTC), so endpoints decode without the ASTC bit
interleave, and the 2/3-subset partitions come from precomputed pattern
tables rather than a 32-bit hash. Ported via a reference Python decoder
validated against basisu's RGBA32 unpack, then to Scheme; the golden
covers the 13 modes the basisu encoder emits across solid / gradient /
noise / partitioned / dual-plane / LA inputs, byte-for-byte
(`test/uastc.ss`).

### `(gfx meshopt)` — EXT_meshopt_compression

The vertex and index codecs gltfpack emits, plus the filters, from the
meshoptimizer sources.

```scheme
(meshopt-vertex! src slen dst count stride)   ; ATTRIBUTES
(meshopt-index!  src slen dst count stride)    ; TRIANGLES
(meshopt-filter-oct! dst count stride)         ; then, in place
```

The vertex codec is an SoA byte-plane transpose with 2-bit group
selectors over {0,2,4,8}/{0,1,2,4,8} bit widths and zigzag-delta with a
tail-seeded last vertex; the index codec uses edge/vertex FIFOs, the
codeaux table, and LEB128 zigzag free indices
(`meshopt-index-sequence!` handles the sequence variant). Filters:
`meshopt-filter-oct!` (octahedral normals), `meshopt-filter-quat!`
(quaternions), `meshopt-filter-exp!` (exponential). `(gfx gltf)` reads a
compressed bufferView through this as if it were uncompressed. Verified
byte-for-byte against the reference `meshopt_decoder` on gltfpack output —
a plain Box and a rigged Fox exercising free indices, the FIFOs, reset,
and the exp/quat filters (`test/meshopt.ss`).

> Note: gltfpack also emits KHR_mesh_quantization (integer vertex
> formats). That is a separate extension; the meshopt codec here is
> complete, but a fully quantized asset needs quantization dequant before
> it renders correctly end-to-end.

## 6. Effects and games toolkit

### `(gfx fx)` — the effects harness

`(gfx fx)` sits over `(gfx gl)` and wires programs from their own
declarations: a shader authored as `(gfx glsl)` forms already declares
its interface, so `fx-program!` reads the attribute/uniform declarations
back out and does the bookkeeping — locations, interleaved offsets,
uniform slots, staging-memory layout, the rAF loop. A shadertoy-style
fullscreen effect is a handful of lines:

```scheme
(fx-init! canvas)
(define q (fx-fullscreen! fragment-forms))     ; a shadertoy in ~15 lines
(fx-loop! (lambda (t dt)
            (fx-fullscreen-use! q t)
            (fx-fullscreen-draw! q)))
```

`fx-init!` owns staging-memory slots from then on: create resources
through `fx-program!` / `fx-buffer!` / `fx-texture!` / `fx-alloc!`, not
hand-numbered `gl-*!` calls. Attribute setup rides VAOs automatically
(the first `fx-use!` of a program/buffer pair records the pointers, each
later one is a single-word rebind), and scalar/vector uniforms remember
their last value per program and skip the re-send. `fx-program3!` targets
ESSL 3.00, `fx-tf-program!` transform feedback, `fx-ubo!` a uniform
block. `fx-loop!` frames commands around a t/dt callback; `fx-loop-fixed!`
splits physics (fixed cadence) from render (once per frame with a blend
alpha). `fx-ticks!` (the timing pump) and `fx-init-input!` (polled keys /
pointer, with `key-down?`, `pointer-x`, `pointer-lock!`) have no GL
dependency, so a Three.js or WebGPU scene uses them directly. Render
targets: `fx-target!`, `fx-target-hdr!`, `fx-target-mrt!` (a G-buffer,
n half-float attachments one shader fills in one pass), `fx-cube-target!`.
Examples: `examples/fx-plasma.html`, `examples/fx-deferred.html`,
`examples/fx-fps.html`, `examples/arena.html`.

### `(gfx sprite)` — 2D games

`(gfx sprite)` sits over `(gfx fx)` and `(web typeset)`. A glyph atlas
rasterizes each distinct code point once (hidden 2D canvas, one texture
upload), and its measurer doubles as the `measure` for typeset's
`prepare`, so layout and rendering agree glyph for glyph.

```scheme
(fx-init! canvas)
(define at (make-atlas "20px system-ui" 20))
(define bt (make-batch at))
(define lay (layout (prepare "SCORE 42" (atlas-measurer at))
                    800.0 (atlas-line-height at)))
;; ... per frame:
(batch-begin! bt)
(rect! bt 10.0 550.0 120.0 16.0  0.2 0.6 1.0 1.0)   ; a paddle
(draw-text! bt lay 10.0 10.0  1.0 1.0 1.0 1.0)
(batch-draw! bt)                                     ; one draw call
```

Sprites, solid rects (`rect!`, backed by a 2x2 white block at the atlas
origin — solid fills are tinted sprites), and text ride one quad batch:
one buffer upload, one TRIANGLES draw per frame. Coordinates are pixels,
top-left origin. Image sprite sheets ride a separate premultiplied path:
`load-image!` → `make-sheet` → `make-sheet-batch`, with `sheet!` drawing
source rectangles under `'premul` blending. Example:
`examples/breakout.html` (bricks, ball, paddle, and the score text in a
single draw).
