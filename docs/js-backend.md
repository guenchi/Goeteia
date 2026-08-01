# JS backend design

Goal: from the same source the compiler emits either `app.wasm` (the
existing WasmGC backend) or `app.js` -- a functionally equivalent
plain-JavaScript artifact for hosts without WasmGC support.  A small
loader feature-detects WasmGC and picks one.  The JS artifact is a
build product: size and correctness matter, human readability does not.

The pipeline forks only at the last stage.  Reading, syntax-rules
expansion, and every optimization pass are shared; the JS emitter is a
sibling of the wasm byte emitter, walking the same core language:

    literals | quote | if | let | %loop | begin | lambda | set!
    | apply | call/cc | application | ~150 % primitives

Both hosts (Chez stage0 and the self-hosted wasm compiler) must emit
byte-identical JS text, extending the existing cross-host parity check.

## Value representation

The wasm backend's representation maps onto JS almost mechanically;
divergence is what breeds bugs, so we mirror it wherever JS allows.

| Scheme value    | wasm (today)                  | JS               |
|-----------------|-------------------------------|------------------|
| fixnum n        | i31ref, payload `n<<1`        | number `n<<1`    |
| char c          | i31ref, payload `c<<1 \| 1`   | number `c<<1\|1` |
| #t #f () void eof | singleton structs by identity | frozen sentinel objects |
| flonum          | struct{f64}                   | `class Fl{v}`    |
| pair            | struct{car,cdr} mutable       | bare array `[car,cdr]` |
| string          | mutable i8 array              | `Uint8Array`     |
| symbol          | struct{string}                | `class Sym{s}`   |
| vector          | eqref array                   | `class Vec{v}` over a JS array |
| bytevector      | struct{i8 array}              | `class BV{u8}`   |
| bignum/ratio/complex | structs                  | classes, prelude-driven |
| closure         | struct{funcref,env}, dual entry | native JS function |
| record          | RECBASE struct                | `class Rec{rtd,f[]}` |
| JS ref (FFI)    | struct{externref}             | `class JSRef{v}` |

Decisions and the reasoning:

1. **Tagged i31 numbers.**  Fixnums and chars share JS numbers with the
   same low-bit tag the wasm backend uses (`n<<1` / `c<<1|1`).  Tagged
   values stay within +/-2^30, so 32-bit JS bitwise ops are exact,
   `===` gives `eq?`, and every primitive's emit sequence transliterates
   one-to-one from the wasm sequence (`unwrap-int` = `>>1`, `wrap-int` =
   `<<1`).  Untagged numbers were considered and rejected: they lose
   the char/fixnum distinction and diverge from the wasm emit logic.

2. **Flonums box** (`Fl`).  JS cannot distinguish `1` from `1.0`, and
   `fixnum?`/`flonum?`/`eqv?` must.  The flonum fast paths simply
   unbox/rebox; no unboxing optimization for the fallback target --
   it is a compatibility path, not the fast path.

3. **Pairs are bare two-slot arrays**, `[car, cdr]`.  Cons is the
   hottest allocation in Scheme code, and array literals allocate
   markedly faster than class instances on V8 (~3-4x measured; JSC is
   close either way).  `Array.isArray` then answers `pair?` -- which
   is why vectors wrap in `Vec`: a two-element Scheme vector would
   otherwise be indistinguishable from a pair, and a type predicate
   must decide on the single cell in O(1).  Vectors are far colder;
   they pay the one indirection.

4. **Strings are byte arrays** (`Uint8Array`), exactly as in wasm --
   mutable, compared by identity, indexed by byte.  All string
   primitives are array ops; the prelude's UTF-8 handling carries over
   untouched.

5. **`JSRef` stays a wrapper on the JS target.**  Tempting to drop it
   (the value *is* a JS value), but raw JS numbers/booleans would
   collide with the tagged representation.  Wrapping keeps `(web js)`
   -- `->js`, `string->js`, the cached boolean refs -- working
   unchanged.  The bridge protocol itself (nameBuf/argStack) vanishes:
   `%js-get` emits `new JSRef(a.v[name])` directly, `%js-call` a direct
   `.apply`, `%js-fn` a native closure.  No import bridge exists on
   this target.

Truthiness in emitted `if`: `x !== FALSE` (only the false sentinel is
false), mirroring the wasm compare-against-`G-FALSE`.

## Control

- **Self tail calls** are already lowered to `%loop` by the front end;
  `%loop` emits a labeled `for(;;)` with parameter reassignment.  A
  top-level function's direct self tail call (wasm: `return_call`)
  gets the same treatment: every fixed-arity function body rides a
  labeled loop, and the call rebinds parameters and continues.
- **Escape continuations**: `call/cc` throws/catches a sentinel
  `{tok, val}` through native JS `throw`, matching the wasm exception
  lowering one-to-one (one-shot, upward-only, winders replayed the
  same way).
- **Non-self tail calls**: wasm uses `return_call`; JS has no portable
  TCO.  MVP emits plain calls and documents bounded mutual-recursion
  depth as a limitation.  A trampoline is the escape hatch if a real
  program hits the stack limit; do not pay for it up front.

## Runtime kernel

A few hundred lines of JS prepended to every emitted program: the
sentinel objects, the classes above, `%mem-*` over one growable
`ArrayBuffer` (64 KB pages), `%f32x4-*` as scalar loops over a
`Float32Array` view, and IO hooks (`write_byte`/`read_byte`) supplied
by the embedder exactly like the wasm `io` imports.  Everything else
-- generic arithmetic, the numeric tower, string/list library -- is
the prelude, compiled through the same pipeline and shared verbatim.

## Drivers and artifacts

- The input stream gains a `(%target js)` marker (sibling of `%opt`);
  `bin/goeteiac` and `rt/compile.mjs` grow a flag that injects it.
- Output is a single ES module: kernel + program, `export function
  main(io)`.
- `rt/loader.mjs` (~20 lines, handwritten): `WebAssembly.validate` on
  a canned WasmGC snippet -> load `app.wasm` via the existing glue,
  else import `app.js`.

## Testing

`run-tests.sh` grows a third column: every `test/*.ss` compiles to JS
on both hosts (texts must be identical) and runs on node; its output
must equal the `;; expect:` line -- the same oracle the wasm target
answers to, so wasm/JS behavioral parity is checked test-by-test with
zero new fixtures.  Skips are defects, per repo policy.

## Known non-goals

- Readable output (minifier-friendly is enough).
- Unboxed-flonum performance work on the JS target.
- Full TCO (see above).
- SIMD performance: `%f32x4-*` is correct, not fast.
