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

## Generated GLSL is not checked for reserved words

**Symptom**: a shader silently fails to compile at runtime — the
draw produces nothing, with no Scheme-side error.

**Cause**: the s-expression shader DSL passes identifiers through
verbatim.  Naming a local `out`, `in`, `sample`, `filter`, or any
other GLSL keyword produces syntactically invalid GLSL.

**Workaround**: avoid GLSL reserved words for locals and helpers.
When a shader "does nothing", print the generated source with
`glsl->string` and scan it before suspecting anything else.

## Prelude gaps

`flabs`, `flmax`, `flmin`, `flonum->fixnum`, `flexpt`, and the
R6RS list helper `exists` are not provided.  Compose them locally
(`(if (fl<? a b) b a)` and friends) or use `exact` plus fixnum
operations.  Inverse trigonometry (`flasin`/`flacos`/`flatan`/
`flatan2`) lives in `(gfx mat)`, not in the prelude.

## No exponent syntax in the self-hosted reader

**Symptom**: a file compiles under the Chez-hosted driver
(`bin/goeteiac`) but stage1 (`goeteia.wasm` compiling itself) fails
with `unbound variable 1e-3` — the literal was read as a *symbol*.

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

## Capacity limits in the graphics stack

- **32 joints per skin.** The skinning palette is a
  `uniform mat4 u_joints[32]`; `gltf-parse` refuses skins beyond
  it.  Modern humanoid rigs (fingers, face) commonly exceed this —
  a UBO/texture palette path is planned but not present.
- **Staging memory only grows.** `fx-alloc!` is a bump allocator
  with no `free`; every `gltf-fetch!` of a new asset leaks the
  previous one's staging bytes.  Fine for dozens of reloads in an
  editing session (Wasm memory grows on demand); unsuitable for an
  unbounded loader loop.

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

The deliberate deviations from the glTF ideal — nlerp instead of
slerp between rotation keys, wholesale node reset when a clip
poses, the one-transition animation machine, skinned normals
without an inverse-transpose, loop-phase precision on
sub-microsecond clips — are documented where they live, in the
header of `lib/gfx/gltf.ss`.  That header is the contract; this
file only points at it.

## Compiler diagnostics are terse

Runtime traps surface as `unreachable` or `illegal cast` with no
Scheme-level context; a malformed file can report an unexpected
close paren at a position far from the mistake.  Bisect with small
files and keep test expressions one-per-define so the failing
definition identifies itself.  Very large quoted literals traversed
with `for-each` can overflow the expander — build big tables
programmatically instead.

## Source encoding

Source files are read bytewise as latin-1: each byte of a UTF-8
sequence becomes its own character.  Literal UTF-8 text in strings
survives to the output byte-for-byte, so writing it is fine — but
`string-length` counts bytes, and any per-character operation
(`string-ref`, `substring` at an arbitrary index) can split a
multibyte sequence.  Treat non-ASCII literals as opaque; never
index into them.
