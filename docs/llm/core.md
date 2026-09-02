# Goeteia page substrate — core

Goeteia is Scheme compiled to WasmGC. You never hand-write JavaScript.

## The shape of every page: you are the browser half

**The page already exists.** A task is ONE `.ss` file whose TOP LEVEL
runs inside that page, on load. It is not a generator: it writes no
`.html`, and there is no writable filesystem — `call-with-output-file`
fails at run time. Whatever is to appear, this program builds.

Exactly two hosts exist on it, and nothing else:

```
<div id="app">      markup goes here
<canvas id="c">     800 x 600 drawing buffer, pixels go here
```

`get-element-by-id` on any other id answers **null**, and the first
call through a null reference takes the whole program down — a page
whose 3D was right dies before drawing because one lookup missed.

```scheme
(import (rnrs) (web js) (web dom))
(define app (get-element-by-id "app"))
(let ((h (create-element "h1")))
  (set-text! h "hello")
  (append-child! app h))
```

A complete program. No mount point, no `define-wasm`, no `,(raw ...)`,
no `html->document`: those belong to the generator shape at the bottom
of this file, which **this environment does not use**.

## (web dom) — the whole vocabulary

| form | |
|---|---|
| `(get-element-by-id id)` `(query-selector sel)` | find; **null** if absent |
| `(create-element tag)` `(make-text s)` | make |
| `(append-child! parent child)` `(insert-before! p new ref)` `(replace-child! p new old)` | attach |
| `(remove-child! p c)` `(remove-all-children! el)` | drop |
| `(set-text! el s)` `(inner-text el)` | textContent; escaping is not your problem |
| `(set-attribute! el name v)` `(set-style! el prop v)` | an attribute; ONE inline property |
| `(set-inner-html! el s)` | a STRING in — see below |
| `(add-event-listener! el type fn)` | `fn` returns `(js-undefined)` |
| `(computed-style el n)` `(console-log x)` `(document)` `(body)` `(window)` | |

`set-inner-html!` hands one string to the host and **headless
verification parses no elements out of it**: markup delivered that way
has nothing to wire and nothing to count. Build elements — an
`<input>` is `create-element` + four `set-attribute!`s +
`append-child!`, and no control arrives ready-made.

## Import sets by task

| task | imports |
|---|---|
| static page | `(rnrs) (web js) (web dom)` — `(web css)` for a stylesheet |
| interaction | add `(web reactive)` for `signal`/`effect` (optional) |
| 3D | `(rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx) (gfx mat) (gfx mesh)` |
| glTF | add `(gfx gltf)`; writing GLB `(gfx glb)` |
| networking | `(web rpc)` (s-expr wire), `(web json)` `(web fetch)` `(web ws)` `(web sse)` |

JSON arrays are **vectors**, objects alists: `list?` lies both ways; ask `json-array?`.


Check `lib/gfx/` before hand-rolling: `post` bloom/SSAO, `ibl`,
`collide` raycasts, `scene`, `sprite` 2D+text, `sdf`, `gpu`/`sgpu`
WebGPU, `stats` a HUD.

## Coming from R6RS

| you reach for | what to write |
|---|---|
| `mod` `div` `mod0` `div0` | exist — exact integers only |
| `modulo` | none; `mod` differs on a negative divisor |
| `sin` `cos` | exist — error < 1e-9 up to \|x\| ≈ 1e6 |
| `tan` | exists; no absolute error bound (`docs/limits.md`) |
| `flsin` `flcos` `fltan` | `(gfx mat)`, same implementation as `sin`/`cos` |
| `asin` `acos` `atan` | `flasin` `flacos` `flatan2`, `(gfx mat)` |
| `expt` | none — write the literal, or multiply |
| `fx-clear!` | `cmd-clear!`, from `(gfx gl)` |

## 3D quick facts

- `(fx-init! canvas)` takes **any canvas that already exists** — here
  `(fx-init! (get-element-by-id "c"))`. It then owns staging memory and
  every slot: allocate through `fx-alloc!` / `fx-buffer!` /
  `fx-program!`, never with hand-numbered `gl-*!`.
- The drawing buffer is the canvas WIDTH/HEIGHT **attributes**
  (800×600), which is also what `u_resolution` reports; CSS only
  stretches the result.
- `fx-loop!` hands the callback `t` and `dt` in **seconds**, one bridge
  call per frame.
- A mat4 is a column-major 16-vector. **`(m4-mul a b)` applies `b`
  first: `a` is the PARENT frame, `b` the child's own transform.**

```scheme
(define hip   (m4-rotate-y t))                     ; the parent frame
(define upper (m4-mul hip (m4-rotate-z shoulder))) ; child of hip
(define fore  (m4-mul (m4-mul upper (m4-translate 0.0 2.0 0.0))
                      (m4-rotate-z elbow)))        ; child of upper
```

- `(gfx mesh)` sizes are **full extents, never halves**: `(mesh-box w h
  d)` takes edge lengths. Generators and arguments: see T3's example.

## DON'T / DO

**Numbers across the JS boundary** — `docs/limits.md` §1; the single
most expensive trap there is.

- DON'T `(fl* 2.0 (js->number v))` — `js->number` answers a **fixnum**
  whenever the JS value is integral, and `fl+ fl- fl* fl/ fl<? fl=?`
  **trap** on fixnums ("ref.cast failed"). It works until a slider
  reaches an exact stop.
- DO define `(define (num v) (exact->inexact (js->number v)))` and
  route every JS-sourced number through it once, at the boundary.
- DON'T call `num` on a Scheme number — `js->number` on a fixnum is
  itself an illegal cast. Use `exact->inexact` / `fixnum->flonum`.
- DON'T expect `%fl->fx` to round: it truncates. DO
  `(exact (flfloor (fl+ x 0.5)))`.

**Literals and the reader** — `docs/limits.md` §4, §6.

- DON'T write `1e-3` or `1.5e3`: the reader has no exponent syntax and
  reads them as **symbols**. DO write `0.001` in full.
- DON'T write `"\xb7;"`: there is no hex escape either, and it reaches
  the page as the literal text `xb7;`. `\"` `\\` `\n` `\t` are the
  escapes; anything else, write the character itself.
- DON'T index into non-ASCII strings: source is read bytewise as
  latin-1, so `string-length` counts **bytes**. Displaying them is
  fine; treat them as opaque.
- DON'T put >~1000 constants in one procedure (the top level is one
  procedure): "param count of 1001". DO split across procedures.
- DON'T use bitwise operators on operands ≥ 2^29 — `illegal cast`.

**CSS values** — `lib/web/css.ss`. A unit's SECOND argument is the
digits after the point **as written**: `(em 1 20)` = 1.2em, `(em 0 9)`
= 0.9em, `(dec 1 60)` = 1.6. Scheme drops a leading zero, so a THIRD
argument is the minimum width: `(em 0 9 2)` = 0.09em — as `(fl W F
[width])` in the shaders. Or write it as a string (`"0.125em"` is
itself). Exact integers pass through.

**Shaders** — `docs/limits.md` §2, `docs/graphics.md` §2.

- `(fl W F)`'s fraction is the digits as written: `(fl 0 5)` = `0.5`,
  `(fl 2)` = `2.0`, `(fl 0 625)` = `0.625`. A third argument is a
  minimum width, left-padded: `(fl 0 5 2)` = `0.05`. A string passes
  through verbatim.
- A function is `(define (name (T arg) ...) RET stmt ...)`; statements
  are `local` / `set!` / `return` / `discard` / `if` / `if-else` /
  `for`. Arithmetic is **binary**: nest, don't vary.
- **Every name a shader introduces** — locals, uniforms, parameters,
  function names, a `for` index — is checked against the union of the
  GLSL ES 1.00 and 3.00 lists (plus `gl_` and any `__`) at generation
  time, so `out`/`sample`/`filter`/`layout` is a named error from
  `glsl->string`, not a blank canvas. Built-ins are *called*, never
  declared, so `sin`/`mix`/`clamp`/`length`/`dot` pass straight through.
- DON'T `normalize` a vector that can be zero (NaN → a black fragment
  with nothing to say why). DO `(/ v (max (length v) "0.00001"))`.
- DON'T flip normals by hand on double-sided meshes; use
  `gl_FrontFacing`.

**Graphics capacities** — `docs/limits.md` §7. Staging is a bump heap
with **one water mark and no free**: `(fx-release! m)` drops back to
`(fx-mark)`'s level and everything after it dies at once, silently.

## Verify — non-negotiable

`goeteia verify page.ss [--needs draw,interact] [--checks spec.json]`
is the whole loop: it compiles the source, runs it against a mock
`document` and a recording GL context for a few frames, and answers
with a structured verdict. The spec format is `docs/verify.md`.

1. Assert what was **drawn** (`drawElements` counts, uniform values)
   and what is **on the page** (elements, text, style) — not that "a
   value appeared somewhere". An input that changes nothing is not
   wired, and `--needs interact` settles that differentially: two runs
   with identical frame timing, one given the input, one not.
2. A mock's testimony is weak evidence: when it disagrees with a real
   browser, believe the browser and fix the mock.
3. `goeteia pack page.ss out.html` ships the finished page as one
   self-contained file that fetches nothing; `--selfcheck` takes the
   module back out of the artifact and proves it behaves identically.

## Appendix: the generator shape (NOT used by this substrate)

Goeteia can also run a `.ss` at BUILD time: the program writes an
`.html` with `(web html)` and compiles **mount points** (`define-js` /
`define-wasm` / `define-wasm-js`, spliced with `,(raw name)`) into
separate artifacts. That needs a writable filesystem and a build step,
and its browser half is the mount body, not the top level. **Not here**:
this page is already open, the top level IS the browser half, and code
inside a mount point silently never runs — no error, nothing drawn.
