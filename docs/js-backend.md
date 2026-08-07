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
| bignum          | struct{limb vector}           | native `BigInt`  |
| ratio/complex   | structs                       | classes, prelude-driven |
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
  trampolines -- but only where it must.  A pre-emission fixpoint
  over the top-level tail-call graph finds the callees whose tail
  chains can reach a cycle (mutual recursion, variadic self calls);
  tail calls to those return a `TC` thunk, and call sites keep their
  `TR` unwind only for callees that may actually return one.
  Everything else calls straight through: an acyclic chain of direct
  tail calls is bounded by the static function count, so constant
  stack survives.  Closures always ride the indirect protocol
  (`TCI` builds the thunk, `IC` sites keep `TR`).  Direct calls stay
  compile-time arity-checked; indirect ones check at bounce time,
  the same moment wasm's adapter would trap.
- **Exports are a call site with no caller inside the module**, so
  nothing out there would unwind a thunk.  An exported function that
  the bounce analysis says may return one is handed to the host
  wrapped in `TR`; the rest go out as the bare function, so their
  `Function.length` still reports the real arity -- the wrapper's
  rest parameter reports 0, which would diverge from the wasm
  target's adapter arity for every export if it were applied
  unconditionally.

## Runtime kernel

A few hundred lines of JS prepended to the emitted program -- but
only the parts the program reaches.  The kernel is split into groups
with declared dependencies:

| group    | contents                                            | deps        |
|----------|-----------------------------------------------------|-------------|
| `core`   | sentinels, pair/vector/string ops, control (Esc, trampoline), checks | always      |
| `fl`     | `Fl` box, flonum checks/conversions                 | core        |
| `sym`    | `Sym`, symbol checks                                | core        |
| `bv`     | `BV`, bytevector checks                             | core        |
| `num`    | `Ratio`/`Cx` classes (bignums are native `BigInt`)  | core        |
| `rec`    | `Rec`, record literals                              | core        |
| `membuf` | the `WebAssembly.Memory` object (64 KB pages -- real grow-failure and old-view detachment; hosts with no WebAssembly at all get a plain-ArrayBuffer stand-in, keeping restricted embedded JS environments runnable) | core        |
| `mem`    | `%mem-*` accessors, `%f32x4-*` scalar loops over a `Float32Array` view | membuf, fl  |
| `ffi`    | `JSRef`, the `(web js)` bridge, `globalThis` proxy  | membuf      |

Emission registers the groups each surviving primitive or literal
uses (registration happens after DCE, so dead code pulls nothing),
and the module ships exactly that closure -- a page script that never
touches the FFI carries no `JSRef`, a numeric program no bridge, and
only staging-memory users pay for the memory accessors.  IO hooks
(`write_byte`/`read_byte`) are supplied by the embedder exactly like
the wasm `io` imports.  Everything else -- generic arithmetic, the
numeric tower's algorithms, string/list library -- is the prelude,
compiled through the same pipeline; a `%target-case` expansion form
lets the prelude fork where the hosts differ (only the branch for
the compiling backend expands), which is how the integer layer rides
native `BigInt` here while wasm keeps its limb arithmetic: bignums
ARE host bigints (`typeof` dispatch, literals emit as `123n`, `BNRM`
renormalizes back to a tagged number whenever the value fits the
untagged fixnum range `[-2^29, 2^29-1]` -- the range whose `n<<1`
still fits i31, so the two targets promote to bignum at the same
magnitude), and the limb machinery never reaches a js module.
DCE also drops top-level definitions whose initializers are pure
construction, so unused prelude tables cost nothing.
The emitted text itself is compact by construction: short
deterministic names (the Scheme names stay recoverable through
`xports`), defensive parentheses squashed by a string-safe text
pass.

### What DCE is allowed to drop

Both targets share `prune-dead`, so the rule matters here for the
same reason it matters for wasm: how much of the prelude a small
program pays for.  An unreferenced top-level definition may vanish
only when evaluating its initializer can neither perform IO nor
**observably fail** -- a dropped definition must not delete an error
the program would otherwise have raised.  Pure, therefore: literals,
`quote`, `lambda`, and `cons`/`vector`/`list`/`%record` over pure
arguments, plus `if`/`begin`/`let` built from those.

Two edges are easy to get backwards:

- `make-vector` and `string` are **not** pure.  Neither performs IO
  and both only allocate on success, but each validates its
  arguments first -- `make-vector` rejects an invalid length,
  `string` rejects a non-character -- and that failure is observable.
  A dead `(define x (make-vector -1))` must still trap.
- A bare variable reference is pure only when the name **resolves**:
  to another top-level definition, to a primitive, or to an
  enclosing `let` binding inside the initializer.  An unbound name
  keeps the initializer alive so ordinary name resolution can report
  it, instead of a typo in dead code compiling silently.

Everything else -- any other call -- stays impure and roots the
definition.

## Drivers and artifacts

- The input stream gains a `(%target js)` marker (sibling of `%opt`);
  `bin/goeteiac` and `rt/compile.mjs` grow a flag that injects it.
- Output is a single ES module: kernel + program, `export function
  main(io)`.
- `rt/web.mjs`'s `loadGoeteiaAuto(url, fallback)`:
  `WebAssembly.validate` on a canned WasmGC snippet -> load
  `app.wasm` via the existing glue, else run the fallback.
  `fallback` is either a CSS selector for an inert inline
  `<script type="goeteia/js">` tag (the single-file page, zero extra
  requests) or a `.js`/`.mjs` URL.  The URL shape is lazy: a WasmGC
  engine never fetches it, and the file caches apart from the page.
  `?goeteia=js` forces the fallback, so it can be exercised on a GC
  engine.
- The external-file fallback is **fetched as text and evaluated per
  launch**, not imported as a module namespace.  A module namespace
  is cached by the host, so a second launch would re-enter a kernel
  whose module-scoped state -- the staging memory, the FFI locals --
  is whatever the first launch left behind.  `runGoeteiaInline` puts
  each launch in a fresh `Function` scope instead (the emitted text
  is an ES module, so scoping it needs only the `export` keywords
  removed); the browser's HTTP cache still serves the second fetch.
- `(conjure mode body...)`: the mount point as a language
  form.  Inside a host program the body compiles as an INDEPENDENT
  program -- its own prelude, its own imports in a fresh scope -- and
  the whole form becomes one HTML string constant.  `mode` is `js`
  (the module inline, run directly), `wasm` (loaded from a `data:`
  URI, or from `(wasm-url "...")`), or `auto` (both artifacts plus
  the loader pick).  wasm and auto sections inline the runtime glue
  (jsbridge + web.mjs, module plumbing stripped) that the drivers
  supply through a `(%conjure-rt ...)` stream directive, so the page
  depends on nothing beside itself and each auto section's fallback
  tag gets a unique `goeteia-conjure-N` id.  The drivers
  mark the prelude boundary with `(%prelude-end)` and resolve each
  embed block's imports separately; sub-compilations run before the
  host's own state is built (every backend entry resets state, so
  ordering is what makes re-entry safe), and embed units use a
  constant pseudo-location so both hosts emit identical bytes.
  Long section strings split into chunked literals rejoined at
  runtime (wasm's `array.new_fixed` caps at 10000 operands).  See
  `examples/counter-page.ss` -- a site generator whose interactive
  half compiles inside its own mount point.
- **Mount-shaped data is data.**  A generator manipulates lists that
  can look exactly like mount points, so materialization is
  suppressed under `quote` outright, and under `quasiquote` it is
  suspended by nesting depth and resumes inside `unquote` /
  `unquote-splicing`.  `` `(conjure ...) `` therefore stays a list,
  while `` `(div ,(conjure ...)) `` -- the shape site generators
  actually write -- still mounts.  All three resolvers (the
  compiler's `embed-expand`, the Chez driver's form walk, the
  `rt/compile.mjs` text scan) track the depth identically; the text
  scanner additionally unwinds prefix-recorded shifts when the
  enclosing list closes, since a reader macro binds to one datum.
  Fixing one resolver alone re-opens host divergence in the other
  direction, so the cases are asserted in `test/conjure.ss` and run
  on both hosts.
- The define- family wraps the modes into named definitions, the
  head's shape picking the artifact's home, like `define` itself:
  `(define-js name body...)` embeds the module inline while
  `(define-js (name "app.js") body...)` references the URL and
  writes the self-running module file when the generator runs --
  pages sharing one module let the browser cache it across them;
  `(define-wasm name body...)` embeds the module as a `data:` URI
  while `(define-wasm (name "app.wasm") body...)` references the
  URL and writes the file; `define-wasm-js` does the same and adds
  the JS fallback -- the name's order is the load preference.
  A three-element head, `(define-wasm-js (name "app.wasm" "app.js")
  body...)`, puts **both** artifacts in files and leaves the section
  carrying nothing but the `loadGoeteiaAuto` call -- the lazy shape,
  which a WasmGC engine never pays for.  That written `.js` keeps
  its `export` and gains **no** appended self-running call, the
  opposite of `define-js`'s URL form: the loader runs `main` itself,
  so appending one would run the program twice.  A fallback path on
  any mode but `auto` is an error.
- URLs in a section are escaped for the context they land in, and
  the two contexts differ.  `define-js`'s URL goes into an HTML
  attribute, where a quote closes the attribute and `<` can start a
  tag, so it gets markup escapes (`&amp; &quot; &#39; &lt; &gt;`) --
  a JS `\x27` escape would be copied through literally there.  The
  loader-call URLs sit in single-quoted JS string literals inside a
  `<script>`, so they get `\xNN` escapes for the control range,
  `'`, `\`, and `<` (which would otherwise let a URL spell an HTML
  end tag).  Underneath both, because these strings are also written
  as *filesystem paths*, every byte outside the unreserved URL path
  set is percent-encoded first (`/` preserved), so a `#`, `?`, or
  `%` in a filename cannot turn into a fragment, a query, or an
  escape on the way back.

### Runtime primitives

`rt/web.mjs` is the browser half of the loader story, and it factors
into pieces a page can reach individually:

| primitive | what it does |
|-----------|--------------|
| `runGoeteiaBytes(bytes)` | instantiate an already-compiled module against the DOM bridge and await its `main` |
| `loadGoeteia(url)` | `fetch` + `runGoeteiaBytes` |
| `runGoeteiaInline(text)` | run a `--js` module from text, in a fresh scope |
| `compileGoeteia(source, compilerUrl)` | compile Scheme text in the browser, returning module bytes |
| `compileGoeteiaFrom(urls, compilerUrl)` | fetch a source list in parallel, join in order, compile |
| `loadGoeteiaAuto(url, fallback)` | the two-artifact entry above |
| `hasWasmGC()` | the engine probe `loadGoeteiaAuto` uses |

The compile pair exists because a page that ships *sources* instead
of a binary -- "compiled by Goeteia in your browser" -- otherwise
hand-rolls the same twenty lines: instantiate `goeteia.wasm` with its
stdin wired to the source text and its stdout to a byte sink, then
instantiate the result.  Splitting `loadGoeteia` into fetch plus
`runGoeteiaBytes` is what lets the bytes path and the URL path share
one instantiation -- including the retry for engines that advertise
`WebAssembly.Suspending` and then reject the import.

`compileGoeteia` surfaces the **compiler's own diagnostics**.  The
compiler writes errors to the same stdout it writes module bytes to
and then traps, so catching the trap and reporting `cause.message`
would reduce every source error to the engine's `unreachable`.  The
accumulated output is decoded first and becomes the thrown error's
message, with the original trap kept on `.cause` and the raw text on
`.output`.  `compileGoeteiaFrom` concatenates its sources in
dependency order -- dependencies before dependents, since the
compiler splices each `(library ...)` and treats `(import ...)` as a
no-op.

### Page-global handles

The glue publishes four handles on `globalThis`:

    __goeteia_load          loadGoeteia
    __goeteia_run           runGoeteiaBytes
    __goeteia_compile       compileGoeteia
    __goeteia_compile_from  compileGoeteiaFrom

They exist because of a reachability problem with a real cause.
"Fallback" hides two unrelated dimensions:

- **Engine fallback** -- the same program on an engine without
  WasmGC.  This is mechanical, and `define-wasm-js` automates it.
- **Capability degradation** -- doing something *else* when WebGL2
  or a layout box is missing.  This carries ordering (reveal,
  measure, probe, only then fetch) and recovery (undo the reveal
  after a trap), which no macro can generate.  It is application
  logic, so it is written as another mount point: a `define-js`
  section that probes and then decides what to load.  Degradation
  deliberately did NOT become macro clauses: a `require`/`on-fail`
  vocabulary would grow into a template language and still could not
  express the ordering.

Such a gating section is itself a compiled Goeteia program, and
`loadGoeteia` lives in the glue's *module* scope, where nothing
outside can see it.  The handles are the bridge.  Ordering works out
because any `wasm`/`auto` section's glue is a `<script
type="module">` that runs before later scripts in document order, so
the handles are set by the time a gating section calls one.

The handles are set by the *host* glue in plain JS, on the real
`globalThis`, which is why the `__goeteia_` prefix is harmless here:
the bridge's per-instance shadowing of that namespace intercepts
**writes** from a compiled module, while a read falls through to the
real global when the instance has never written the key.  A module
may therefore read these handles, but must not use the prefix for
state it wants another module instance to see -- see the namespace
rule in `docs/graphics.md`.

## Testing

`run-tests.sh` grows a third column: every `test/*.ss` compiles to JS
on both hosts (texts must be identical) and runs on node; its output
must equal the `;; expect:` line -- the same oracle the wasm target
answers to, so wasm/JS behavioral parity is checked test-by-test with
zero new fixtures.  Skips are defects, per repo policy.

Whatever has no Scheme-level oracle gets a node harness of its own,
`test/*.mjs`, run from the same script: the emitted JS's trap and
arity behavior (`js-backend-*`), the bridge's per-instance globals
(`jsbridge-instance`), and the loader and library lifecycles that
only misbehave on the *second* run of a page -- the compiler's
diagnostics surviving a trap (`web-compile-diagnostics`), an
external `.js` fallback getting a fresh runtime per launch
(`web-external-fallback-fresh`), and loop retirement in `(gfx fx)`
and `(web glyphs)`.

## Known non-goals

- Readable output (minifier-friendly is enough).
- Unboxed-flonum performance work on the JS target.
- SIMD performance: `%f32x4-*` is correct, not fast.
- JSPI suspension: `js-await` hands the promise back unawaited, and
  the kernel shims `WebAssembly.Suspending`/`promising` out of the
  eval and `js-get` views so feature probes honestly answer no and
  callers take their callback route.
