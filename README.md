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
- Dead code elimination: programs carry only what they use

See [Design](#design) for the object representation, the calling
convention, and the milestone-by-milestone build log.

## Web

A small UI stack over the JS bridge, in `lib/web/`:

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
- `(web react)` — embed Goeteia components into an existing React
  app: `react-component` registers a factory the React side wraps
  in one `useEffect` (`rt/react.mjs`); props flow in as JS objects,
  the dispose thunk flows back as a JS function
- `(web three)` — reactive 3D scenes over Three.js: the `s3d`
  template builds the scene graph once, unquoted attributes become
  signal-driven holes, and `three-loop!` pumps frames into Scheme —
  bridge traffic is O(changes), rendering stays on the GPU
- `(web gl)` — raw WebGL through a command buffer: Scheme encodes a
  frame of GL commands as words in the shared linear memory and one
  bridge call replays them; vertex data uploads zero-copy from the
  same memory (`examples/gl-particles.html`: 10,000 particles,
  one call per frame)
- `(web glsl)` — GLSL as s-expressions: `glsl->string` is a pure
  function from a shader form list to GLSL source (the `(web css)` of
  shaders), so shaders compose with `append`/`map` and helper
  functions and verify headlessly; infix `+ - * /`, `(fl 0 50)` float
  literals (no Scheme flonums, no printer noise), `attribute`/
  `uniform`/`varying`, and `define`d functions
- `(web rpc)` — s-expression RPC to a Scheme backend (Igropyr's
  `(igropyr sexpr)` is the server half): `write` on one side, a safe
  whitelisted parser on the other, so exact integers and ratios cross
  the wire intact and there is no codec at all
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

## Usage

Node 22+ (or any Wasm GC engine) is all you need: the compiler ships
as `goeteia.wasm`, itself a Wasm GC module.

```
$ npm install goeteia
$ goeteia compile program.ss program.wasm   # compile to a wasm module
$ goeteia run program.wasm                   # run a compiled module
$ goeteia program.ss                         # compile and run in one step
$ goeteia dev [port]                          # live-reload dev server (cwd)
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

`goeteia dev` serves the current directory, watches its Scheme/JS/CSS
sources, and on every save runs the project's `./build.sh` (which
recompiles any changed page module) before pushing a live reload to
every open tab. Edit a `.ss`, save, and the page re-renders.

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
$ goeteia dev            # or: python3 -m http.server
```

then visit `http://localhost:8100/playground.html`. It compiles and
runs your Scheme in a Web Worker, entirely in the browser.

## Tests

```
$ ./run-tests.sh
```

Each file in `test/` declares its expected output in its first line
and runs through both the Chez-hosted and the self-hosted compiler.

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
  → expand      (macros: derived forms now, syntax-case later)
  → analyze     (top-level defines vs. program expressions)
  → codegen     (per function: expression tree → instruction list)
  → emit        (instruction list → binary module)
```

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
objects first-class Scheme values.  Seventeen `js.*` imports carry
property access, calls, constructors, and string/number conversion
(names and strings cross byte by byte, call arguments through a push
protocol).  Scheme closures convert to callable JS functions: the
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

## License

MIT.  See LICENSE.
