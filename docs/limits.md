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

## GLSL reserved words are refused at generation time

**Symptom**: `glsl->string` raises `illegal local variable name: out
-- reserved in GLSL ES 1.00 (keyword)` on a shader that used to
render.

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

## Prelude gaps

`flabs`, `flmax`, `flmin`, `flonum->fixnum`, `flexpt`, and the
R6RS list helper `exists` are not provided.  Compose them locally
(`(if (fl<? a b) b a)` and friends) or use `exact` plus fixnum
operations.  Inverse trigonometry (`flasin`/`flacos`/`flatan`/
`flatan2`) lives in `(gfx mat)`, not in the prelude.

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

## Capacity limits in the graphics stack

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
read: list opened at line 3 column 5 never closed
read: string opened at line 2 column 3 never closed
read: unexpected ) at line 2 column 3
```

Two things to know about those numbers:

- **Columns count bytes, from 1.**  Source is read as latin-1 (see
  *Source encoding* below), so a three-byte UTF-8 character occupies
  three columns.  A tab is one column.
- **Under stage1 the line is a line of the compiler's input
  stream, not of your file.**  `rt/compile.mjs` feeds the compiler
  the prelude, the runtime glue and every resolved import ahead of
  your source, and a reader error is raised before the `(%loc …)`
  markers that map stream lines back to files have been consumed.
  The column is exact either way, and the *relative* distance
  between two reported lines is exact.  When the absolute line
  matters, compile the same file with `bin/goeteiac`: the
  Chez-hosted driver reads each file on its own, so its reader
  errors carry true source positions.

The self-hosted reader's positions are exact for `read` at runtime —
a program reading from a string or file port gets the real line and
column of its own input, and a port that is read from more than once
keeps counting where it left off.

## Source encoding

Source files are read bytewise as latin-1: each byte of a UTF-8
sequence becomes its own character.  Literal UTF-8 text in strings
survives to the output byte-for-byte, so writing it is fine — but
`string-length` counts bytes, and any per-character operation
(`string-ref`, `substring` at an arbitrary index) can split a
multibyte sequence.  Treat non-ASCII literals as opaque; never
index into them.
