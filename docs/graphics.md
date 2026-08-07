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
attributes (`cmd-vertex-attrib-h!`), a GPU frame timer
(`gl-gpu-timer!` / `gl-gpu-ms`), and pixel readback. Readback is the
upload path run backwards, and stays a command like any other:
`cmd-read-pixels!` encodes a rectangle plus a staging address, and the
replayer hands `gl.readPixels` a view aimed straight at that address —
so once the frame's one `cmd-flush!` returns, the `w*h*4` RGBA8 bytes
are simply there for `%mem-u8-ref`, with no copy and nothing to await.
It reads whichever framebuffer is bound where the command sits in the
stream, and rows arrive bottom-up as GL delivers them. Picking under
the cursor, saving a screenshot and reading back a compute-style pass
all go through it — at the price documented under "Pixel readback
stalls the frame" in `docs/limits.md`. The `cmd-pos` and `cmd-draws`
counters
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
`out` forms declare pinned MRT outputs. A block member may itself be an
array — `((array mat4 256) u_joints)` — which is how a block carries a
palette; std140 gives a `mat4` array the tight 64-byte stride, so such a
block maps one to one onto a run of matrices in staging memory.
Every position that *introduces* a name — the three global
declarations, `out`, uniform-block names and members, function names and
parameters, `local`, and a `for` index — is checked against the GLSL ES
1.00 and 3.00 keyword and reserved lists (plus the `gl_` prefix and any
`__`), and a hit is an error from `glsl->string` naming the identifier
and the declaration that introduced it. Both dialects refuse the union
of the two lists, so `sample`, `filter`, `layout` and `smooth` are
refused even when emitting 1.00: the forms are dialect-neutral and one
call away from `glsl300-vs->string`. *References* to built-ins
(`gl_Position`, `gl_FragColor`, `gl_FrontFacing`) are untouched — the
check is about declarations. `glsl-check` runs it alone, without
rendering.

`glsl-attributes`, `glsl-uniforms`, `glsl-varyings` and
`glsl-uniform-blocks` read the interface back out of the forms — how
`(gfx fx)` wires programs automatically, and what
`fx-program-blocks` reports for a built program (block members never
reach the uniform table, so that is the only place to ask whether a
program carries one).

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

Every position that *introduces* a name — the three global declarations,
`struct` names and members, `storage` bindings, function names and
parameters, `local`, and a `for` index — is checked against WGSL's own
keyword and reserved lists, so a name the browser would reject is an
error here instead of a pipeline that silently fails to build.
`wgsl-check` runs it alone. The table is WGSL's, not the GLSL one
respelled: `in`, `out`, `inout` and `void` are GLSL keywords that WGSL
leaves free, `fn` / `let` / `var` / `loop` / `alias` / `override` go the
other way, and WGSL reserves `__` as a prefix only where GLSL reserves it
anywhere. Each renderer is held to its own specification.

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

The inverses come the same way — `flasin`, `flacos`, `flatan`,
`flatan2`, each a reduction onto one series, accurate to 1e-7 across
its whole domain (measured within a few ulps of a host `Math`).
`flasin` / `flacos` **clamp** arguments outside [-1, 1] instead of
answering NaN, because a dot product of two unit vectors leaves that
interval by an ulp as a matter of course; `flatan2` follows
`Math.atan2`'s signs, answers 0 at the origin, and does not
distinguish negative zero. `q-slerp` interpolates two unit
quaternions `#(x y z w)` along the shortest arc at a constant angular
rate (`t` unclamped, near-parallel pairs falling back to a normalized
lerp) — the rate is what separates it from the nlerp
`gltf-animate!` samples with.

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
the stride follows the ATTRIBUTES the asset carries, never the
material: position+normal alone is 24 bytes, a `TEXCOORD_0` (or
anything past it) adds the 8-byte uv slot, and `TANGENT`, `COLOR_0`
and the skin inputs add 16, 16 and 32. `gprim-layout` names what is
present, in interleave order — that, not `gprim-textured?`, is the
contract `gltf-draw!` matches a program against: it compares name AND
component count per attribute, because wrong widths can cancel out in
the total (a `vec2` position beside a `vec4` normal spans the same 24
bytes as two `vec3`s while every offset past the first is wrong). A
program declaring per-instance `i_*` attributes is refused too — this
entry point binds no instance buffer, so the shader would read zeros.
Skinning is a dimension rather than a shader variant:
`(gltf-skin-shader vs)` turns any static vertex shader into its skinned
form — padding the slots the interleave always carries, rewriting
`a_pos`/`a_normal`/`a_tangent` through the joint matrix, and leaving the
varyings alone so the same fragment shader still pairs. The palette it
declares is `uniform mat4 u_joints[32]`, which is all ESSL 1.00 can
carry; `(gltf-skin-shader3 vs)` is the same combinator with the other
carrier — a std140 block `Skin { mat4 u_joints[256]; }` — for rigs with
fingers and a face. The two differ in nothing but that declaration: the
shader body reads `u_joints[i]` either way, and the built-in
`gltf-skin-vs` / `gltf-skin-vs3` are both derived from `mesh-tex-vs`
rather than written out. `(gltf-skin-program3! vs fs)` builds the big
one and wires its block to `gltf-skin-binding` (1, leaving 0 to the
`(gfx scene)` frame-globals block) in one call. `gltf-draw!` then picks
the upload from the *program*: a `u_joints` uniform means the
three-word `cmd-uniform-matrices4s!` path, a `Skin` block means
`cmd-ubo-data!` + `cmd-bind-ubo!`. The two are mutually exclusive by
construction — a block member has no uniform location of its own — so
nothing depends on declaration order, a small skin draws on either, and
the one combination that cannot work, a skin past 32 on a 32-slot
program, is refused by name instead of truncated. A renderer
driving its own shaders reads `gltf-prim-world` for a primitive's
current model matrix — the identity for a skinned one, since glTF has
a skinned mesh ignore its node transform and the palette already
carries the pose (`gprim-world` is the bind pose, and neither follows
the optional root). `gprim-textured?` says whether there is a base
color image to sample, which is a different question from what layout
a program must declare. Animation is sampled and blended:
`gltf-animate!` poses a clip completely each frame (looping, nlerp
rotations; the nodes a clip touches return to bind first, so a channel
the clip does not drive reads as bind rather than as whatever ran
before), `gltf-animate-blend!` crossfades two clips posed
independently — which is what lets clips with different channel sets
fade correctly — `gltf-weights!` /
`gprim-morph` drive morph targets, and `anim-machine` / `anim-goto!` /
`anim-update!` package named states over clips with per-transition
fades. `gltf-animation-names` and `gltf-animation-duration` report a
clip's name and its length in seconds — the period `gltf-animate!`
wraps its clock into.
The skeleton composes without a boxed matrix anywhere: each node's local
is `m4s-tqs!` in closed form, parent chains multiply in SIMD
parents-first into a resident staging arena, and `gltf-joint-palette!`
hands back the palette's address for a three-word upload. `gltf-parse`
works on any GLB bytes already in staging, so parsing verifies headlessly
(`test/gltf.ss`). Examples: `examples/fx-gltf.html` (lit Box),
`fx-gltf-tex.html` (textured), `fx-fox.html` (the rigged Fox, Survey /
Walk / Run crossfade on keys 1-3).

### `(gfx glb)` — writing GLB

The other direction: a mesh built or edited in staging memory leaves as
a file any glTF tool reads. `glb-write!` wraps an interleaved vertex
block and an index block that are *already there* — nothing is repacked
— and hands back `(base . length)`, the same pair `gltf-parse` takes, so
a round trip is one expression.

```scheme
(define loc (glb-write!
              (list (list '(position normal uv) vbase vcount ibase icount
                          'color (vector 0.8 0.2 0.2 1.0)))))
(gltf-parse (car loc) (cdr loc))       ; read it straight back, or
                                       ; copy the range out to a Blob
```

A primitive is a plain list — `(layout vbase vcount ibase icount
. options)` — not a record only this library can build, so a mesh
generator, a decoder or a parsed asset can all feed it. `layout` names
the attributes present in the order they occupy the interleave, from
the same vocabulary `gprim-layout` reports: `position` `normal` `uv`
`tangent` `color` `joints` `weights`, each float32 at
12/12/8/16/16/16/16 bytes. `glb-stride`
and `glb-offset` give a layout's byte stride and an attribute's place
inside it, which is what a generator writing the vertices needs anyway.
The options are a key/value tail: `color` for a `baseColorFactor`
material (absent means no material, and the loader's own default
answers), `index-u32?` for the index width — defaulting to `#t` past
65536 vertices, where `(gfx gltf)` switches too — `stride` for a
padded interleave, and `joints-u16?` for the `JOINTS_0` element width.
`icount` 0 writes a non-indexed primitive.

What comes out is one buffer, a bufferView per vertex block (with a
`byteStride`), per index block and per joint block, one accessor per
attribute plus one per index array, one mesh holding every primitive,
the node array and one scene — with the JSON chunk space-padded and the
BIN chunk zero-padded
to the 4-byte alignment the container specification requires, and with
POSITION's mandatory `min`/`max` computed from the data rather than
guessed. Indices are checked against the vertex count as they are
written: an index that names a vertex the primitive does not own is
refused here rather than drawing garbage in a viewer that never says
why.

`JOINTS_0` is the one attribute that does not stay where it lies. glTF
stores joint indices as unsigned bytes or shorts while the interleave
`(gfx gltf)` builds carries them as floats, so the writer narrows them
into a block of their own and leaves the interleave's 16 bytes
unreferenced; `WEIGHTS_0`, which glTF is happy to take as float32, is
described in place like everything else. A joint index that is not a
whole number the skin owns is refused rather than narrowed, and a
layout naming only one of `joints`/`weights` is refused too — half a
skin binding is a primitive no reader can pose.

Round trip: for a layout in the canonical interleave order (`position
normal`, then `uv`, then `tangent`, then `color`, then `joints` and
`weights`) `gltf-parse`
reproduces the vertex bytes exactly — `test/glb.ss` compares them byte
for byte. Other layouts are written faithfully but come back
canonicalized, because the loader always gives a primitive a normal
(`+y` when the file has none) and always carries a uv slot once
anything past normal is present. Exporting a parsed asset therefore
needs no adapter beyond the accessors `(gfx gltf)` already exports:

```scheme
(glb-write!
 (map (lambda (p)
        (list (gprim-layout p) (gprim-vbase p)
              (quotient (gprim-vbytes p) (gprim-stride p))
              (gprim-ibase p) (gprim-icount p)
              'color (gprim-color p)
              'index-u32? (gprim-index-u32? p)))
      (gltf-prims g)))
```

#### Skeletons and clips

`glb-write!` takes a key/value tail of its own for everything that is
not one primitive's vertices — `nodes`, `mesh-node`, `skin`, `anims` —
and each of the four is optional, so the call above stays exactly what
it was.

```scheme
(glb-write!
 (list (list '(position normal uv joints weights) vbase vcount ibase icount))
 'nodes (list (list "mesh" -1)                    ; (name parent T R S)
              (list "j0" -1 (vector 1.0 0.0 0.0))
              (list "j1"  1 (vector 2.0 0.0 0.0)))
 'mesh-node 0
 'skin (list '(1 2) ibm-base)                     ; joint nodes, inverse binds
 'anims (list (list "walk"
                    ;; (node path times values keys interpolation)
                    (list (list 1 'rotation t-base r-base 3 'linear)
                          (list 2 'scale    t-base s-base 3 'step)))))
```

`nodes` is the whole node array in file order. A node is `(name parent
translation rotation scale)`, or `(name parent . options)` with the
same three as keys — a transform is a vector or list of numbers and an
option key is a symbol, so the two spellings never collide. `parent` is
an index, or `-1`/`#f` for a root; children and the scene's roots are
*derived* from it, so a parent that does not exist, a node that is its
own parent, and a parent chain that closes on itself are all refused at
the call. Omit `nodes` and you get the single node the writer emitted
before, carrying the mesh. `mesh-node` says which node carries the mesh
(default 0); that node is also the one that gets the skin, and it gets
it only when some primitive really has `JOINTS_0` — a skinned node
whose mesh has no joint inputs is a file `gltf-parse` cannot pose.

`skin` is `(joint-node-indices inverse-bind-matrices)`. The second
element may be a staging base of `njoints` tightly packed mat4s, a
sequence of 16-number matrices, or `#f` for identity binds.

`anims` is a list of clips, each `(name channels)`; a channel is
`(node path times values keys interpolation)`. `path` is
`translation`, `rotation`, `scale` or `weights`; `interpolation` is
`linear`, `step` or `cubic` (glTF's own `"LINEAR"`/`"STEP"`/
`"CUBICSPLINE"` also work), defaults to `linear`, and may equally ride
in a key/value tail as `'interpolation`. Under `cubic` the values
source holds the specification's in-tangent/value/out-tangent triples —
`3 × keys` elements, in that order — and a morph-`weights` channel
takes `'components` for how many targets a key carries, since glTF
writes those as loose scalars rather than as vectors. Every animation
input accessor gets the `min`/`max` the specification demands, scanned
out of the times themselves; times that go backwards are refused,
because no sampler has a reading for them.

`times`, `values` and the inverse binds are **sources**, and a source
is deliberately wider than staging memory: either a base (tightly
packed float32) or a Scheme sequence of elements, each element a
sequence of `ncomp` numbers — or a bare number when `ncomp` is 1. That
is what makes a parsed asset re-exportable without a staging round
trip, because `(gfx gltf)` hands its skeleton and its clips back as
vectors. `gltf-nodes` gives the runtime node table (`tx ty tz`, `qx qy
qz qw`, `sx sy sz`, matrix, parent), `gltf-skins` gives `#(joint-nodes
inverse-binds)`, and `gltf-anims` gives `#(name channels duration
touched)` with each channel `#(node path times values cursor
interpolation in-tangents out-tangents)`. The one shape that needs
rebuilding is `CUBICSPLINE`: the parser splits the triples into three
vectors and the writer wants them whole again.

```scheme
(define (node->desc v)                     ; a runtime node -> a descriptor
  (list #f (vector-ref v 11)
        (vector (vector-ref v 0) (vector-ref v 1) (vector-ref v 2))
        (vector (vector-ref v 3) (vector-ref v 4)
                (vector-ref v 5) (vector-ref v 6))
        (vector (vector-ref v 7) (vector-ref v 8) (vector-ref v 9))))

(define (chan->desc ch)
  (let* ((times (vector-ref ch 2)) (vals (vector-ref ch 3))
         (interp (vector-ref ch 5)) (n (vector-length times))
         (out (if (eq? interp 'cubic)
                  (let ((o (make-vector (* 3 n) #f)))   ; in, value, out
                    (let loop ((i 0))
                      (if (= i n)
                          o
                          (begin
                            (vector-set! o (* 3 i) (vector-ref (vector-ref ch 6) i))
                            (vector-set! o (+ (* 3 i) 1) (vector-ref vals i))
                            (vector-set! o (+ (* 3 i) 2) (vector-ref (vector-ref ch 7) i))
                            (loop (+ i 1))))))
                  vals)))
    (append (list (vector-ref ch 0) (vector-ref ch 1) times out n interp)
            (if (eq? (vector-ref ch 1) 'weights)
                (list 'components (vector-length (vector-ref vals 0)))
                '()))))

(glb-write!
 (map (lambda (p) ...) (gltf-prims g))     ; as above
 'nodes (map node->desc (vector->list (gltf-nodes g)))
 'mesh-node 0
 'skin (list (vector-ref (vector-ref (gltf-skins g) 0) 0)
             (vector-ref (vector-ref (gltf-skins g) 0) 1))
 'anims (map (lambda (a)
               (list (vector-ref a 0)
                     (map chan->desc (vector->list (vector-ref a 1)))))
             (vector->list (gltf-anims g))))
```

`test/glb-skin.ss` runs exactly this on a four-joint chain carrying a
skinned mesh and three clips, then compares the two generations
accessor by accessor and pose by pose. Read the skeleton back *before*
posing it, though: `gltf-nodes` is the runtime table, which
`gltf-animate!` writes into.

Not written yet: morph targets, textures, cameras, materials beyond a
base colour, and more than one skin per file.

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
`(fx-read-target! t base)` copies a whole target back into staging
memory at `base` (`w*h*4` RGBA8 bytes from `fx-alloc!`); like
`fx-bind-target!` it leaves the framebuffer bound, and on a
multisampled target it reads the resolve framebuffer, so
`fx-resolve!` has to run first.

Staging memory itself is a bump heap, and `(fx-mark)` / `(fx-release! m)`
are the way back down it: `fx-mark` reads the current water level,
`fx-release!` drops it to `m`, and the next `fx-alloc!` hands those bytes
out again. Bracket a rebuild with the pair and a loader loop stays
bounded instead of leaking the previous scene:

```scheme
(define m (fx-mark))
(define asset (gltf-fetch! url))
;; …tearing the whole asset down again:
(fx-release! m)
```

The bookkeeping stops there: there is no per-object free, and
**everything** allocated after the mark dies at the release, silently and
at once — pose arenas, palettes, resident mesh bases, readback buffers,
any staging address a record still holds. Release whole build phases
only, and drop the handles with them. `fx-release!` refuses a mark below
the 64 KiB command region or above the current level (the error names
both numbers), but nothing can tell it who still holds a pointer. Wasm
memory never shrinks; only the pointer moves, so peak occupancy is the
highest level ever reached. See `docs/limits.md`.

Examples: `examples/fx-plasma.html`, `examples/fx-deferred.html`,
`examples/fx-fps.html`, `examples/arena.html`.

#### Loop retirement, and the `__goeteia_*` namespace rule

A long-lived page runs a program more than once — a live editor
recompiles on Run, a demo switcher launches the next demo. Each run
starts its own `requestAnimationFrame` chain, and nothing in the DOM
tells the old chain to stop, so without a retirement protocol the
loops stack up forever and the page gets slower with every Run.

`fx-init!` bumps a generation counter; `fx-ticks!` captures the value
it saw and stops rescheduling itself as soon as the counter moves
past it. `(gfx fx)` handles this for you — the trap is in *where the
counter lives*.

The counter key is deliberately **outside** the `__goeteia_`
namespace. The JS bridge shadows `globalThis.__goeteia_*` per module
instance: a write under that prefix lands in the instance's own map,
never on the real global, and `__goeteia_mem` is answered from the
instance's own exports. That isolation is the point of the prefix —
and it means a counter stored under such a key could never be seen
by a *different* module instance, which is precisely the case this
counter exists for, since the previous run is a different instance.
(Reads still fall through to the real global for keys the instance
has not written, which is how host-planted values like
`__goeteia_canvas` and the loader handles arrive.) The general rule:
`__goeteia_*` is per-instance state a module writes for itself, and
anything that must cross module instances needs a key outside that
prefix.

`fx-init!` takes an optional second argument, the **owner** object
the counter is stored on:

```scheme
(fx-init! canvas)          ; owner defaults to the JS global
(fx-init! canvas mount)    ; scoped to a node you keep
```

The default is the global scope, and that default is deliberate.
Scoping looks tidier, but on a live page every run builds a fresh
subtree, so scoping the counter to anything the run itself created —
the canvas, its parent — hands each run a private counter that
starts at zero, and no run can ever retire the one before it. That
is the leak the counter exists to prevent, reintroduced.

Pass an owner only for the case it is for: one page running two
independent widgets that must not retire each other. Then the owner
must be a node that **outlives the runs** — a container you keep,
never one a run creates.

`(web glyphs)` runs the same protocol for its pointer-tracking
lifecycle, on its own key outside the same prefix, but it can afford
a narrower default: the owner defaults to the **first glyph root**,
which is an element the page already had (that is what the text was
exploded from), not something the run built — so two glyph sets on
one page keep independent lifecycles by default, and the global is
used only when the group list is empty. Both `glyphs-track!` and
`glyphs-dodge!` take the optional owner and return an idempotent
disposer, and a `MutationObserver` calls that disposer when every
tracked root has left the document — so switching to non-glyph UI
drops the listeners without the page having to know it should. A
stale disposer removes its own listeners but leaves the counter and
the cleanup slot alone if a newer run has already claimed them.

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
