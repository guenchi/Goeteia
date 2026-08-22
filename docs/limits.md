# Known limits and sharp edges

Every entry here was hit in real use.  Each gives the symptom you
will actually see, the cause, and the workaround — in that order,
because the symptoms are usually far away from the causes.  Read
this file before debugging anything that "makes no sense"; both
humans and coding agents lose the most time to the first two
entries.

## Numbers across the JS boundary

**Symptom**: `RuntimeError: ref.cast failed to cast reference to
target heap type` the moment a value from JavaScript meets float
arithmetic — often only on SOME inputs, so the code appears to work
until a slider hits an integral position.

**Cause**: `js->number` returns a *fixnum* whenever the JS value is
integral (`0`, `1`, a slider at an exact stop), and a flonum
otherwise.  The `fl+ fl- fl* fl/ fl<? fl=?` family traps on fixnum
operands — they do not coerce.

**Workaround**: normalize at the boundary, once:

```scheme
(define (num v) (exact->inexact (js->number v)))
```

Route every JS-sourced number through such a helper before it can
reach `fl` operators.  Do not sprinkle `exact->inexact` at use
sites; the call you forget is the one that traps.

## GLSL and WGSL reserved words are refused at generation time

**Symptom**: `glsl->string` raises `illegal local variable name: out
-- reserved in GLSL ES 1.00 (keyword)`, or `wgsl->string` raises
`illegal local variable name: let -- a WGSL keyword`, on a shader
that used to render.

**Cause**: the s-expression shader DSL passes identifiers through
verbatim, so naming a local `out`, `in`, `sample`, or `filter` used
to produce syntactically invalid GLSL — the shader failed to compile
inside the driver, the draw produced nothing, and nothing on the
Scheme side said a word.  Every position that introduces a name is
now checked against the GLSL ES 1.00 and 3.00 keyword and reserved
lists: `attribute` / `uniform` / `varying`, `(out loc T name)`,
uniform-block names and members, function names and parameters,
`local`, and a `for` index.  Identifiers beginning `gl_` and any
identifier containing `__` are refused too; both are reserved by
the specs.

**Workaround**: rename the identifier — the message gives the name
and which declaration introduced it.  Two things worth knowing
before you argue with it:

- Both dialects refuse the *union* of the two reserved lists, so
  `sample`, `filter`, `layout` and `smooth` are refused even when
  emitting ESSL 1.00, which does not reserve them.  The forms are
  dialect-neutral; accepting such a name would only move the blank
  frame to the day someone hands the same shader to
  `glsl300-vs->string`.
- *References* to built-ins (`gl_Position`, `gl_FragColor`,
  `gl_FrontFacing`) are untouched.  The check is about declarations,
  and only about names you introduce — the DSL's own structure words
  (the `out` heading an `(out 0 vec4 name)` form, `attribute`,
  `varying`, `uniform-block`) are not identifiers.

`glsl-check` runs the same check without rendering.

`(gfx wgsl)` closes the same hole on its side, with its own table:
`wgsl->string` (both form lists) and `wgsl-compute->string` refuse a
declared name that is a WGSL keyword or reserved word — the lists in
sections 16.1 and 16.2 of the W3C WGSL specification — at every
position that reaches the module as an identifier: `attribute` /
`uniform` / `varying`, `struct` names and members, `storage`
bindings, function names and parameters, `local`, and a `for` index.
`wgsl-check` runs it alone.  The two tables are deliberately *not*
translations of one another, and neither renderer is held to the
other's vocabulary:

- `in`, `out`, `inout` and `void` are GLSL keywords that WGSL leaves
  free, while `fn`, `let`, `var`, `loop`, `alias`, `override` and
  `mut` go the other way.
- WGSL reserves the two underscores as a *prefix* only (section 2.2),
  where GLSL reserves `__` anywhere — so `a__b` is a legal WGSL name
  and an illegal GLSL one.  A lone `_` is refused: in WGSL it is the
  phony-assignment token, not an identifier.
- `gl_` is a GLSL prefix rule and not a WGSL one.  `gl_Position`,
  `gl_FragColor` and `gl_FragCoord` are rewritten on the way into a
  WGSL module, so they never reach it as names at all.

A form list that renders for one backend can therefore be refused by
the other.  That is the honest answer — the two languages' reserved
sets simply differ — and it is better found at generation time than
as a blank canvas on whichever backend the page picks.

## Prelude gaps

`flabs`, `flmax`, `flmin`, `flonum->fixnum`, `flexpt`, and the
R6RS list helper `exists` are not provided.  Compose them locally
(`(if (fl<? a b) b a)` and friends) or use `exact` plus fixnum
operations.  Inverse trigonometry (`flasin`/`flacos`/`flatan`/
`flatan2`) lives in `(gfx mat)`, not in the prelude.

`div`, `mod`, `div0` and `mod0` are present but accept **exact
integers only** — deliberately narrower than R6RS, which defines them
over the reals.  A flonum, a ratio or a zero divisor raises.  There is
no `modulo`: `mod` is the floored operation and answers in `[0,|d|)`,
so it differs from R5RS `modulo` whenever the divisor is negative
(`(modulo 7 -2)` is `-1`; `(mod 7 -2)` is `1`).  There is no `expt`
either — write the literal, or build it by multiplication.

**Since 2026-08-21** the reader handles a string **line continuation**
as R6RS §4.2.5 requires: a backslash followed by intraline whitespace, a
line ending and more intraline whitespace produces *nothing*, so a long
literal can be broken across source lines. A backslash followed by
intraline whitespace and then no line ending is now an **error**; before
that date it silently produced that byte, and the continuation itself
became a newline — which meant the same source read as two different
strings under this reader and under Chez's. See `docs/determinism.md`
D3.

## Trigonometric accuracy

`sin` and `cos` reduce the argument with one rounded subtraction of
`k*2pi` and then evaluate one odd polynomial.  Two consequences are
worth knowing before trusting a digit:

**The bound degrades with amplitude.** Error is under `1e-9` measured
up to `|x| ~ 1e6`.  Past that the reduction itself is what loses
precision, because `k*2pi` is rounded once: at `2^29` the measured
error is about `2.4e-8`.  Nothing warns you; the answer just gets
less right the further out you go.

**`tan` carries no absolute bound at all.** It is `sin/cos`, and for
`t = s/c` the first-order error is

```
dt ~ ds/c - s*dc/c^2
```

so the numerator's error is amplified by `1/cos x` and the
denominator's by about `1/cos^2 x`.  `tan` can therefore degrade far
faster than the two functions it is built from — measured `1.2e-9` at
`x = 942508`, where `cos x ~ 0.35`, nowhere near a pole and well
inside the `1e6` domain that holds for `sin`/`cos`.

At the poles it diverges outright, and **the sign of the divergence is
not a libm's**:

| x | goeteia | a host libm |
|---|---|---|
| `1.5707` | error ~`5.6e-8` | — |
| `1.5707963267948966` (pi/2) | `+inf` | ~`1.63e16` |
| `4.71238898038469` (3pi/2) | `-inf` | ~`+5.4e15` |

The mechanism is the reduction: it lands `cos` on **exactly** zero
where a libm's cosine is a tiny non-zero of a particular sign, so the
quotient overflows and takes its sign from the numerator alone.  A
caller that branches on `(fl<? (tan x) 0.0)` near a pole will disagree
with a host libm about which side it is on.  Away from the poles and
at small `|x|`, `tan` is as good as `sin`/`cos`.

`(gfx mat)`'s `flsin`, `flcos` and `fltan` are the same implementation
under other names — one polynomial for the whole system — so all of
the above applies to them unchanged.

## No exponent syntax in the self-hosted reader

**Symptom**: a file compiles under the Chez-hosted driver
(`bin/goeteiac`) but stage1 (`goeteia.wasm` compiling itself) fails
with

```
unbound variable ~s; exponent literals are not supported by this
reader -- write the constant out 1e-3
```

— the literal was read as a *symbol*.  A name that merely contains
an `e` (`elf-3`, `vec3`) gets the plain `unbound variable` message;
the hint appears only for something shaped like a number.

**Cause**: the self-hosted reader has no `1e-9` / `1.5e3` exponent
syntax.

**Workaround**: write small and large constants out in full
(`0.000000001`), as the existing `(gfx mat)` code does.  Anything
that must pass the full test matrix (stage0 + stage1 + JS backend)
cannot use exponent literals.

## Bitwise operations and big operands

**Symptom**: `illegal cast` trap in integer code that looks
correct.

**Cause**: bitwise operators work on i31-tagged fixnums and an
operand at or beyond 2^29 traps (measured: 2^29 - 4 works, 2^29
exactly traps).

**Workaround**: keep bitwise operands strictly below 2^29 — split
wider values, or use lookup tables for hashing-style code.

## About a thousand constants per procedure

**Symptom**: the module compiles, then refuses to load —
`WebAssembly.instantiate(): param count of 1001 exceeds internal
limit of 1000`.  Nothing in the source names a function with a
thousand parameters.

**Cause**: constants are hoisted per emitted function, and the
module's top level is one function.  A body carrying more than ~1000
of them — a big table of float literals, a long list of strings —
pushes that function's type past the 1000-parameter ceiling every
wasm engine imposes.  The prelude's own constants count toward a
top-level body's share, so the ceiling arrives sooner there than in
a procedure you write.

**Workaround**: split the body across procedures.
`test/determinism-battery.ss` carries 600 float literals as fifteen
procedures of forty and loads fine; the same 600 at top level do
not.  Grouping does not help if one procedure still holds them all —
it is a per-function limit, not a per-module one.

## Capacity limits in the graphics stack

- **Index width is per-geometry, and follows the vertex count.** A u16
  index names vertices 0..65535, so a mesh of 65536 vertices still fits
  and one of 65537 does not. `(gfx scene)` picks the width when it
  builds a geometry and again when it welds a group, from the total that
  weld will contain; welded groups may mix u16 and u32 sources, each
  read at the width it was written and all written out at the group's.
  A u32 index buffer is **twice the memory** of a u16 one for the same
  triangle count, which is why the choice is per-geometry rather than a
  setting. The u32 path is WebGL 2 (`UNSIGNED_INT` indices), the same
  baseline the 256-joint skin path already needs.

  **Since 2026-08-21.** Before that the scene graph was u16 throughout:
  a mesh past 65536 vertices was accepted in silence and drawn with
  `UNSIGNED_SHORT`, so every index above the boundary named some other
  vertex — a wrong picture, with nothing said. The mesh layer
  (`mesh-index-u32?`, `mesh-index-bytes`) and the command layer
  (`cmd-index-data32!`, `cmd-draw-elements32!`) had both carried u32
  all along; only the wiring between them was missing. Welding a group
  past the boundary was skipped rather than truncated, so the parts drew
  separately and correctly; they weld now.
- **256 joints per skin, and 32 on the ESSL 1.00 path.** There are
  two palette carriers, and which one applies is a property of the
  *program*, not of the asset.  `gltf-skin-shader` declares
  `uniform mat4 u_joints[32]` and works on any WebGL 1 context;
  `gltf-skin-shader3` declares `layout(std140) uniform Skin { mat4
  u_joints[256]; }` and needs WebGL 2 (build it with
  `gltf-skin-program3!`, or `fx-program3!` plus a
  `gl-uniform-block!` to `gltf-skin-binding`).  `gltf-parse` refuses
  a skin past 256 — that is what a conforming WebGL 2 context
  guarantees, since `MAX_UNIFORM_BLOCK_SIZE` is at least 16384 bytes
  and std140 gives a `mat4` array a 64-byte stride.  A skin between
  33 and 256 joints loads, but drawing it with a 32-slot program is
  refused by `gltf-draw!` rather than silently truncated.  A small
  skin is legal on either.
- **Staging memory is a bump heap with one water mark, no `free`.**
  `fx-alloc!` only ever moves a pointer up.  The one way back is
  the water-mark pair: `(fx-mark)` reads the current level,
  `(fx-release! m)` drops it back to `m`, and the next `fx-alloc!`
  hands those same bytes out again.  So a loader loop that rebuilds
  a scene is bounded — mark before the build, release when tearing
  it down:

  ```scheme
  (define m (fx-mark))
  (define asset (gltf-fetch! url))   ; …and everything it allocates
  ;; …later, tearing the whole asset down:
  (fx-release! m)                    ; asset and its handles are now dead
  ```

  The discipline is entirely the caller's, and it is absolute:
  **everything** allocated after the mark dies at the release, at
  once and with no diagnostic.  Pose arenas, joint palettes,
  resident mesh bases, readback buffers, any staging address a
  record still carries — after the release each one points at
  whatever the next allocation writes there.  Release only whole
  build phases, and drop the handles in the same breath; a mark
  taken before something that must outlive the release is a
  use-after-free that nothing will report.  `fx-release!` does
  check its argument (below the 64 KiB command region, or above the
  current level, is an error naming both numbers), but it cannot
  see who still holds a pointer.

  Wasm memory itself never shrinks — only the pointer moves.  Peak
  occupancy is the highest water level ever reached, not the sum of
  everything ever allocated.  Without marks that sum grows without
  bound: every `gltf-fetch!` of a new asset leaks the previous
  one's staging bytes, which is fine for dozens of reloads in an
  editing session and unsuitable for a loop.  GL objects are a
  separate question: re-uploading into the same slot already
  replaces, and the browser reclaims what nothing references.

## Pixel readback stalls the frame

`cmd-read-pixels!` / `fx-read-target!` are synchronous by
construction: the whole point is that the bytes are in staging
memory the instant `cmd-flush!` returns, and that requires the
driver to finish everything already queued before it can answer.
So a readback drains the pipeline — the CPU waits for the GPU, and
the GPU then starts the next frame with nothing buffered ahead of
it.  One small read per frame (picking under the cursor) is
usually affordable; a full-canvas read every frame is not, and
neither is reading a target the same frame that drew it.

There is no asynchronous escape hatch here.  WebGL 2's
`PIXEL_PACK_BUFFER` + fence path (read this frame, collect two
frames later) would need a command that *returns* on a later
flush, which the buffer protocol has no shape for.  Where latency
matters more than freshness, read a target that was drawn a frame
or two ago and accept the lag.

Two sharp edges besides the cost:

- **Rows come back bottom-up.**  Row 0 of the result is the bottom
  row of the rectangle, GL's own convention — flip it yourself
  when handing the bytes to anything that expects top-down images.
- **A multisampled target cannot be read.**  `cmd-resolve!` it and
  read the resolve framebuffer; `fx-read-target!` picks the
  resolve framebuffer for you, but it can only show what
  `fx-resolve!` has already blitted there.

## Animation semantics

- **`gltf-animate!` wraps its clock, so `t = duration` is the
  clip's FIRST keyframe, not its last.**  The phase is
  `t - dur*floor(t/dur)`, a half-open `[0, dur)`, which is right
  for a clip that loops and wrong for every question of the form
  "what does this clip end on".  Asking `gltf-animate!` for the
  end pose silently returns the start pose: no error, no NaN, just
  a joint at the wrong angle — and on a clip that turns a joint
  most of the way round, wrong by most of a turn.  Negative `t`
  wraps too, by floor rather than truncation, so `-0.25` of a
  one-second clip reads `0.75`.  Use **`gltf-pose-at!`** where the
  clock should be held at both ends instead — scrubbing, seeking,
  reading a final pose, sampling `N+1` times inclusive of both
  ends, holding the last frame of a one-shot.  Inside `[0, dur)`
  the two are the same function, which is exactly why the
  difference goes unnoticed until an endpoint is asked for.
- **A clip's duration is its largest timestamp**, not the span of
  its timestamps, and both entry points clamp or wrap into
  `[0, duration]`.  Keyframes at negative times are therefore
  unreachable through either.

The deliberate deviations from the glTF ideal — nlerp instead of
slerp between rotation keys, wholesale node reset when a clip
poses, the one-transition animation machine, skinned normals
without an inverse-transpose, loop-phase precision on
sub-microsecond clips — are documented where they live, in the
header of `lib/gfx/gltf.ss`.  That header is the contract; this
file only points at it.

## Compiler diagnostics are terse

Runtime traps surface as `unreachable` or `illegal cast` with no
Scheme-level context.  Keep test expressions one-per-define so the
failing definition identifies itself.  Very large quoted literals
traversed with `for-each` can overflow the expander — build big
tables programmatically instead.

### Reader errors say where the construct *opened*

An unbalanced file used to be reported at its end, which is never
where the mistake is.  The reader now names the opening position of
whatever was left open:

```
read: list opened at src/scene.ss line 41 column 3 never closed
read: string opened at src/scene.ss line 7 column 12 never closed
read: unexpected ) at src/scene.ss line 88 column 20
```

Two things to know about those numbers:

- **Columns count bytes, from 1.**  Source is read as latin-1 (see
  *Source encoding* below), so a three-byte UTF-8 character occupies
  three columns.  A tab is one column.
- **The file and line are the ones you wrote**, even though the
  compiler is fed a single stream with the prelude, the runtime glue
  and every resolved import spliced in ahead of your source.  The
  `(%loc …)` markers that `rt/compile.mjs` plants at each file
  boundary set a reader-side origin, so the reader maps its stream
  line back before printing.  An error inside a library names that
  library.

The same positions come out of `read` at runtime: a program reading
from a string or file port gets the real line and column of its own
input (no file name — nothing told it one), and a port that is read
from more than once keeps counting where it left off.

## Source encoding

Source files are read bytewise as latin-1: each byte of a UTF-8
sequence becomes its own character.  Literal UTF-8 text in strings
survives to the output byte-for-byte, so writing it is fine — but
`string-length` counts bytes, and any per-character operation
(`string-ref`, `substring` at an arbitrary index) can split a
multibyte sequence.  Treat non-ASCII literals as opaque; never
index into them.
