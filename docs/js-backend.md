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
| pair            | struct{car,cdr} mutable       | object literal `{t:"pair",a,d}` |
| string          | mutable i8 array              | `Uint8Array`     |
| symbol          | struct{string}                | `class Sym{s}`   |
| vector          | eqref array                   | bare JS array    |
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

3. **Pairs are tagged object literals**, `{t:"pair",a,d}`.  Cons is
   the hottest allocation in Scheme code, and at heap scale the
   object literal wins decisively: one inline-slot allocation, where
   a bare array is a JSArray plus a separate elements store (~28x
   slower allocating 4M pairs on V8) and `new Pair(...)` pays the
   construct path (~15x).  Walks and the `x.t==="pair"` predicate
   also beat array indexing and `Array.isArray` on both V8 and JSC.
   Reading `.t` is safe on every value -- numbers box transparently,
   every other representation lacks the property -- and the string
   literal comparison is an interned pointer check.  Vectors are
   bare JS arrays, `Array.isArray` answering `vector?` unambiguously
   since pairs no longer occupy that shape.  (Closure encodings were
   also measured and rejected: they collide with `procedure?`, which
   cannot move out of the way, and lose 4-7x on V8.)

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
- **Non-self tail calls**: wasm uses `return_call`; the JS target
  trampolines.  A non-self tail call returns a `TC` thunk instead of
  calling, and every non-tail call site unwinds through `TR`, so tail
  chains -- mutual recursion included -- run in constant JS stack.
  Direct calls stay compile-time arity-checked (bare `TC`); indirect
  ones check at bounce time (`TCI`), the same moment wasm's adapter
  would trap.

## Runtime kernel

A few hundred lines of JS prepended to every emitted program: the
sentinel objects, the classes above, `%mem-*` over one basic
`WebAssembly.Memory` (64 KB pages -- real grow-failure and old-view
detachment semantics; a host with no WebAssembly at all falls back to
a plain-ArrayBuffer stand-in, keeping restricted embedded JS
environments runnable), `%f32x4-*` as scalar loops over a
`Float32Array` view, and IO hooks (`write_byte`/`read_byte`) supplied
by the embedder exactly like the wasm `io` imports.  Everything else
-- generic arithmetic, the numeric tower, string/list library -- is
the prelude, compiled through the same pipeline and shared verbatim.

## Drivers and artifacts

- The input stream gains a `(%target js)` marker (sibling of `%opt`);
  `bin/goeteiac` and `rt/compile.mjs` grow a flag that injects it.
- Output is a single ES module: kernel + program, `export function
  main(io)`.
- `rt/web.mjs`'s `loadGoeteiaAuto`: `WebAssembly.validate` on a
  canned WasmGC snippet -> load `app.wasm` via the existing glue,
  else run the fallback (an inline tag or a lazily imported file).
- `(conjure mode body...)`: the mount point as a language
  form.  Inside a host program the body compiles as an INDEPENDENT
  program -- its own prelude, its own imports in a fresh scope -- and
  the whole form becomes one HTML string constant.  `mode` is `js`
  (the module inline, run directly), `wasm` (loaded from a `data:`
  URI, or from `(wasm-url "...")`), or `auto` (both artifacts plus
  the loader pick); `(rt "...")` locates rt/web.mjs.  The drivers
  mark the prelude boundary with `(%prelude-end)` and resolve each
  embed block's imports separately; sub-compilations run before the
  host's own state is built (every backend entry resets state, so
  ordering is what makes re-entry safe), and embed units use a
  constant pseudo-location so both hosts emit identical bytes.
  Long section strings split into chunked literals rejoined at
  runtime (wasm's `array.new_fixed` caps at 10000 operands).  See
  `examples/counter-page.ss` -- a site generator whose interactive
  half compiles inside its own mount point.
- The define- family wraps the modes into named definitions:
  `(define-js name body...)`, `(define-wasm (name "app.wasm")
  body...)` (writes the module file when the generator runs),
  `(define-wasm-inline name body...)` (`data:` URI), and
  `(define-wasm-js (name "app.wasm")...)` /
  `(define-wasm-js-inline name ...)` shipping the wasm-plus-fallback
  pair.  `-inline` always means the wasm rides in the section; the
  `wasm-js` order is the load preference.

## Testing

`run-tests.sh` grows a third column: every `test/*.ss` compiles to JS
on both hosts (texts must be identical) and runs on node; its output
must equal the `;; expect:` line -- the same oracle the wasm target
answers to, so wasm/JS behavioral parity is checked test-by-test with
zero new fixtures.  Skips are defects, per repo policy.

## Known non-goals

- Readable output (minifier-friendly is enough).
- Unboxed-flonum performance work on the JS target.
- SIMD performance: `%f32x4-*` is correct, not fast.
- JSPI suspension: `js-await` hands the promise back unawaited, and
  the kernel shims `WebAssembly.Suspending`/`promising` out of the
  eval and `js-get` views so feature probes honestly answer no and
  callers take their callback route.
