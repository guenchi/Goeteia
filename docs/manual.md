# Goeteia Developer Manual

## Introduction

Goeteia is a self-hosting Scheme-to-WebAssembly-GC compiler that compiles itself and runs on any engine with Wasm GC support (Node 22+, current browsers, wasmtime). Where Wasm GC is missing, the same source compiles to a functionally equivalent plain-JavaScript module instead—see [Compiling to JavaScript](#compiling-to-javascript). This manual documents what you need to know to build applications *on top of* Goeteia, assuming you already understand R6RS Scheme. We cover only Goeteia-specific toolchain, libraries, and behavior; standard R6RS primitives are not documented here. For the complete index of exported procedures, with their signatures, see the [API reference](api.html).

### Reading the Signatures

Each documented procedure gives the call form, a type line, a one-line
description, and — where a result is worth showing — an example with `=>`.

The type line reads left to right: it begins with `func` (the procedure
itself), the arrows run through its arguments, and the last item is the
result; `...` marks a variadic tail. A nullary procedure is just
`func -> result`. A `void` result means the call is made for its **side
effect** (named in the description); a `never` result means it does not
return normally (it raises). A concrete value written after the result
type names exactly what comes back — `func -> *jsObject globalThis`
returns the `globalThis` object. Macros are shown the same way but headed
`syntax:`.

A `*`-prefixed name is a *pointer to a host object*: `*jsObject` (a Wasm
`externref` holding a JS value), and likewise `*domElement`, `*signal`,
`*effect`, `*response`, `*ws`, `*sse`. Other types: `any`,
`string`, `number`, `int`, `boolean`, `symbol`, `list`, `pair`, `vector`,
`alist`, `procedure`, `port`, `hashtable`, `condition`, `datum`, `sxml`,
`raw` (a raw-HTML marker), and `template` (a literal `sx` form).

## Contents

1. [Toolchain and Workflow](#toolchain-and-workflow)
2. [Program Structure](#program-structure)
3. [The Library System](#the-library-system)
4. [Values and Goeteia-Specific Representation](#values-and-goeteia-specific-representation)
5. [Runtime Facilities Beyond Common R6RS](#runtime-facilities-beyond-common-r6rs)
6. [JavaScript FFI](#javascript-ffi)
7. [DOM](#dom)
8. [Reactivity](#reactivity)
9. [Templates](#templates)
10. [HTML and CSS as Data](#html-and-css-as-data)
11. [React Interop](#react-interop)
12. [3D and WebGL](#3d-and-webgl)
13. [Text Layout and Audio](#text-layout-and-audio)
14. [Networking](#networking)
15. [Running in the Browser](#running-in-the-browser)
16. [Testing](#testing)
17. [Porting from JavaScript/TypeScript](#porting-from-javascripttypescript)
18. [Dispatch and Rules](#dispatch-and-rules)
19. [Game Scaffolding](#game-scaffolding)
20. [Simulation](#simulation)
21. [Current Limits and Planned Work](#current-limits-and-planned-work)

## Toolchain and Workflow

### Compiling and Running

Goeteia ships as a precompiled `goeteia.wasm` binary—the compiler itself. To compile a Scheme program and run it:

```bash
node rt/compile.mjs goeteia.wasm program.ss program.wasm
node rt/run.mjs program.wasm
```

The compiler reads `program.ss`, resolves its library imports, and emits `program.wasm`. The runner instantiates the wasm module, calls its exported `main()` function, and prints the result.

A program consists of top-level definitions followed by expressions. The value of the last expression is the program's result:

```scheme
(define (fact n)
  (if (zero? n) 1 (* n (fact (- n 1)))))
(fact 20)  ; prints 2432902008176640000
```

### Script Mode (-O0)

For one-shot scripts, CI iteration, and REPL or playground snippets—anywhere compile latency matters more than runtime speed—Goeteia can compile at `-O0`, trading a little output size for a markedly faster compile. There are three ways to engage it, at three levels:

1. **CLI**: pass `--script` (alias `-O0`) to `rt/compile.mjs`:

   ```bash
   node rt/compile.mjs --script program.ss program.wasm
   ```

2. **API**: pass `{ script: true }` to `compileToBytes` or `compileSource` in `rt/compile.mjs`:

   ```javascript
   await compileToBytes('program.ss', { script: true });
   await compileSource(text, { script: true });
   ```

3. **Stream directive**: a `(%opt 0)` form at the head of the input stream—a directive like `(%loc ...)`, read but never emitted. This is the lowest level, honored by any driver including the in-browser compiler, and it is what the CLI flag and API option set for you.

What `-O0` turns off is exactly the two post-optimizer-batch-2 whole-program analyses whose cost dominates compile time: **flonum function specialization** (a monotonic-demotion fixpoint over every call site) and **named-let loop lowering**. Everything else—inlining, dead-code elimination, and the rest of the established pipeline—stays on, so the output-quality floor is the optimizer-batch-2 level.

The effect on representative site pages is roughly a 35–40% faster compile (168ms→100ms, 123ms→71ms), for output about 5% larger. Semantics are identical: `test/opt0.ss` is a differential oracle run through both compiler stages in CI, checking that the same program computes the same results at `-O0` and at full optimization. Long-running or hot code (renderers, simulations) should keep full optimization; script mode is for when compile latency outweighs runtime speed.

### Compiling to JavaScript

The two targets share everything but the last stage. Passing `--js` emits a plain-JavaScript ES module instead of wasm—the same program, for engines that lack Wasm GC:

```bash
node rt/compile.mjs --js goeteia.wasm program.ss program.js
node rt/runjs.mjs program.js            # optionally: program.js input-file
```

As with `-O0`, the flag is sugar for a stream directive: `(%target js)` at the head of the input selects the JS emitter, and any driver honors it.

The artifact is a single self-contained ES module—the runtime kernel is embedded ahead of the program, so there is no glue file and nothing to import. It exports `main(io)`, which takes the same io hooks the wasm runner supplies, plus `rt` (the sentinel values, for decoding a result) and `xports` (whatever the program declared in `(export ...)`). `rt/runjs.mjs` is the JS-target counterpart of `rt/run.mjs`: same hooks, same result decoding, same printed output. Nor does the artifact need WebAssembly to be present at all: the staging memory behind the SIMD and byte primitives prefers a real `WebAssembly.Memory` (that is what buys exact grow-failure and view-detachment semantics) but falls back to a plain `ArrayBuffer` stand-in where the constructor is missing, so a restricted embedded JavaScript environment still runs the module.

Behavior is identical by construction and checked as such—`run-tests.sh` compiles every test to JS as a third column and holds it to the same `;; expect:` oracle the wasm columns answer to, and the Chez-hosted and self-hosted compilers must emit byte-identical JS text. That identity covers *errors*, not just results: division by zero, out-of-range collection and byte-memory access, wrong operand types, invalid float conversions and arity violations all trap on the JS target where they trap on wasm, and memory growth detaches the old views and answers −1 on failure exactly as `memory.grow` does. A program that traps on wasm fails on JS at the same point, so JavaScript's usual permissiveness never turns a wasm trap into a silently different answer. Wasm remains the fast path; reach for the JS target when you need reach, not speed. See [Running in the Browser](#engines-without-wasm-gc) for how a page picks between the two, and [Current Limits and Planned Work](#current-limits-and-planned-work) for what the JS target costs.

### The Chez Path (Optional)

With [Chez Scheme](https://cisco.github.io/ChezScheme/) installed, you can compile via `./bin/goeteiac`, which may be faster locally:

```bash
./bin/goeteiac program.ss program.wasm
./bin/goeteiac --js program.ss program.js
```

Chez is optional—it's only used for bootstrapping and as an independent verifier of the self-hosted compiler, not a runtime dependency.

### Self-Hosting and the Fixpoint

When you edit the compiler (`src/compiler.ss`), rebuild the snapshot:

```bash
./rebuild.sh
```

This runs:
1. **Candidate**: the current `goeteia.wasm` compiles the source to `candidate.wasm`
2. **Verify**: `candidate.wasm` compiles the source again to `verify.wasm`
3. If byte-identical, `candidate.wasm` becomes the new `goeteia.wasm` snapshot

The fixpoint check ensures the compiler is stable—it always produces identical output from identical input. If you see "FIXPOINT FAILED", your changes broke the self-hosting invariant; check the compiler's top-level form ordering (see design.md).

For a stronger check using Chez as an independent host:

```bash
./build-self.sh
```

This verifies that Chez and the self-hosted compiler produce byte-identical output, guaranteeing correctness across two independent implementations.

## Program Structure

A Goeteia program is a sequence of top-level definitions and expressions. Expressions execute in order; the value of the last expression is the program result:

```scheme
(define x 5)
(define (double y) (+ y y))
(display x)
(double 10)  ; this value is printed by rt/run.mjs
```

### Exports

Top-level definitions are private to the module by default. To expose definitions to the host:

```scheme
(export name1 name2 ...)
```

The `export` form lists names that become wasm exports. Dead-code elimination prunes all unused definitions, so exports are advisory for documentation—use them to mark the API surface.

### Result Decoding

The host decodes the program result as follows:
- **Fixnums** and **characters**: printed as numbers or `#\c`
- **Booleans**, `()`, **symbols**: printed as `#t`, `#f`, `()`, `symbol`
- **Other objects** (pairs, strings, vectors, records, closures): show as `#<object>` unless explicitly converted to a string via `display` or `write`

To inspect results, use the standard writers:

```scheme
(write (list 1 2 3))      ; writes (1 2 3) to stdout
(display "hello")         ; writes hello
(number->string (+ 1 2))  ; "3" — build a string to return/inspect
```

`display`/`write` emit to stdout regardless; only the final *decoded
return value* falls back to `#<object>`.

## The Library System

Libraries are modules—each is one `(library ...)` form in a single `.ss` file.

### Library Declaration

```scheme
(library (name parts...)
  (export item1 item2 ...)
  (import ...)
  ;; definitions and expressions
  )
```

A library named `(math utils)` lives in `math/utils.ss`, found by:
1. The directory of the importing file
2. Its `lib/` subdirectory
3. The toolchain `lib/` directory (where Goeteia's own libraries live)

The first file found is used.

### Imports and Specs

Top-level `(import ...)` forms pull in libraries. The driver resolves imports recursively (dependencies first, each library once) and inlines them:

```scheme
(import (math utils))          ; load math/utils.ss
(import (rnrs lists))          ; builtin rnrs library
(import (only (web js) js-get js-set!))  ; restrict to these exports
(import (except (web dom) alert))        ; import all except alert
(import (rename (web dom) (window w)))   ; alias window to w
(import (prefix (web sx) sx-))           ; prefix all with sx-
```

**Builtin libraries**: `(rnrs ...)` and `(schwasm ...)` are provided by the prelude, compiled into every module. You cannot define them.

### Dead Code Elimination

The compiler prunes unused definitions, so even if a library exports many names, only those actually used are compiled in. This keeps module size small.

## Values and Goeteia-Specific Representation

Goeteia values live in the host engine's garbage-collected heap as first-class objects—Wasm GC structs and arrays on the wasm target, the mirror image of them in JS objects on the JS target. A few aspects differ from portable Scheme, on both:

### Fixnum Range

Fixnums are unboxed 30-bit signed integers: roughly `[-2^29, 2^29)` (specifically `[-536870912, 536870911]`). On overflow, arithmetic automatically promotes to bignums:

```scheme
(+ 536870911 1)       ; gives bignum 536870912
(* 1000000 1000000)   ; products checked in i64, promote if needed
```

### The Numeric Tower

- **Fixnums**: `-536870912` to `536870911`, unboxed and fast
- **Bignums**: arbitrary-precision integers, auto-promoted on overflow
- **Flonums**: IEEE-754 64-bit floats (literals like `1.5`, `+nan.0`)
- **Ratios**: exact rationals — `(/ 1 3)` yields `1/3`, kept exact
- **Complex**: `+2i`, `(make-rectangular 1 2)` → `1+2i`

The full tower is implemented. Arithmetic contagion runs
complex ⊃ flonum ⊃ ratio ⊃ integer: `(+ 1/2 0.5)` → `1.0`,
`(* 2 1/3)` → `2/3`, `(sqrt -1)` → `0+1.0i`,
`(make-rectangular 1 2)` → `1+2i`.

### Float Arithmetic

The `fl` operations are the raw f64 float primitives. Built into an
expression tree they stay **unboxed**: the f64 lives on the wasm stack,
so `(fl+ (fl* a b) (fl* c d))` allocates only for its final result — zero
allocation inside the tree. This is the compute-then-store idiom the
staging memory and `(gfx gl)` command buffers rely on.

```
procedure: (fixnum->flonum n)

func -> int -> number
```
An exact fixnum as a flonum.

```
procedure: (fl+ a b)

func -> number -> number -> number
```
Flonum addition; `fl-`, `fl*`, `fl/` are subtraction, multiplication and
division, same shape.

```
procedure: (flsqrt x)

func -> number -> number
```
Flonum square root; `flfloor` and `fltruncate` round toward −∞ and toward
zero, same shape.

```
procedure: (fl<? a b)

func -> number -> number -> boolean
```
Flonum ordering; `fl=?` is equality.

```
procedure: (flonum? x)

func -> any -> boolean
```
Whether `x` is a flonum.

```scheme
(fl+ (fixnum->flonum 3) (fl* (fixnum->flonum 2) (fixnum->flonum 5)))
=> 13.0
```

### Records

`define-record-type` compiles to GC structs with an identity slot (a unique pair), so `point?` is one `ref.test` plus one `ref.eq`. Records are mutable via field accessors if the field is declared `(mutable ...)`.

### Low-Level Primitives

Names prefixed with `%` (e.g., `%js-ref?`, `%make-string`) are low-level Wasm primitives for internal use. Use the library wrappers instead (`js-ref?` in `(web js)`, `make-string` in `(rnrs strings)`).

## Runtime Facilities Beyond Common R6RS

### Ports and I/O

**String ports** are first-class objects:
```scheme
(define out (open-output-string))
(display "hello" out)
(get-output-string out)  ; => "hello"

(define in (open-input-string "5"))
(read in)                ; => 5
```

**File ports** (Node only; browser stubs return errors):
```scheme
(call-with-input-file "data.txt" read)
(call-with-output-file "out.txt" (lambda (p) (display "hello" p)))
```

**Console**: `display`, `write`, `newline` default to stdout (the `io.write_byte` import).

```
procedure: (open-output-string)

func -> port
```
A fresh in-memory output port that accumulates written bytes.

```
procedure: (get-output-string port)

func -> port -> string
```
The text accumulated in a string output port.

```
procedure: (open-input-string s)

func -> string -> port
```
An input port that reads from the string `s`.

```
procedure: (call-with-input-file path proc)

func -> string -> procedure -> any
```
(Node only.) Open `path`, call `(proc port)`, close, and return its
value. Browser stubs raise.

```
procedure: (call-with-output-file path proc)

func -> string -> procedure -> any
```
(Node only.) Open `path` for writing, call `(proc port)`, close, and
return its value.

#### `(web fs)`: Whole Files In and Out of Staging Memory

The ports above give a file one character at a time. `(web fs)` gives
it as **bytes in staging memory**, which is where every `(gfx …)`
decoder wants its input and where every encoder leaves its output — a
GLB to parse, a PNG to decode, an encoded image to write back.

The destination block is the caller's. There is one bump heap and
`(gfx fx)` owns it, so a second allocator would hand the same bytes
out twice; `(web fs)` therefore imports nothing but `(rnrs)`, and a
page that reads a file does not drag the GL harness in.

```scheme
(define base (fx-alloc! 900000))                   ; the caller allocates
(define n (fs-slurp! "asset.glb" base 900000))
(define g (gltf-parse base n))
```

**Host body.** A filesystem is not something every host has: a browser
page has none, and neither do the verify and compile hosts. Every open
fails there, and `(web fs)` says so *by name* rather than trapping
deeper down. `fs-exists?` answers `#f` — on a host with no filesystem
nothing exists, which is the true answer. The readers raise naming the
path, because a failed read-open means either a missing file or a host
without a filesystem and the two are indistinguishable from inside.
The writers raise naming the *host*, because a failed write-open is
not ambiguous: a host with a filesystem accepts the open and defers
any failure to the close.

```
procedure: (fs-slurp! path base)   (fs-slurp! path base cap)

func -> string -> int -> int
```
Read the whole file into staging memory at `base`; answer the byte
count. With `cap` the read is refused past `base + cap`. A file that
outgrows either that or the staging memory is a **named error at the
byte that would leave it** — not a trap with no path in it, and not a
quiet overwrite of whatever `fx-alloc!` handed out next. The two
bounds are reported apart: one calls for a bigger block, the other for
a bigger memory.

```
procedure: (fs-spit! path base len)

func -> string -> int -> int -> int
```
Write `len` bytes of staging memory starting at `base`; answer `len`.

```
procedure: (fs-slurp-string path)   (fs-spit-string! path s)

func -> string -> string   /   func -> string -> string -> int
```
The whole file as a Scheme string, and the reverse (answering the byte
count). A Goeteia string is UTF-8 bytes and these move one byte per
character, so a UTF-8 file arrives unchanged — this is the shape
`(web json)` reads.

```
procedure: (fs-exists? path)   (fs-size path)

func -> string -> boolean   /   func -> string -> int
```
Whether the file can be opened for reading, and its length in bytes.
`fs-exists?` never raises. `fs-size` reads the whole file to count it
(the host offers no `stat`), so a caller about to slurp the file
anyway should slurp it and take the count `fs-slurp!` returns rather
than ask twice.

### `(web args)`: Command-Line Arguments

A program used to have exactly one channel in from its runner —
standard input, which `rt/run.mjs` fills from a file named on the
command line. That makes "which variant is this run" and "what is the
input" the same stream. `(web args)` is the second channel.

Everything after a bare `--` is the program's own argv; an invocation
without one means exactly what it always meant.

```
$ node rt/run.mjs prog.wasm input.txt -- --frames 34 out/
```

```scheme
(import (rnrs) (web args))
(args-count)          ; => 3
(args-list)           ; => ("--frames" "34" "out/")
(args-ref 0)          ; => "--frames"
```

The host publishes the list at `__goeteia_argv`, the same way a host
hands a worker its canvas (`__goeteia_canvas`) and the module its
memory (`__goeteia_mem`) — the bridge resolves `__goeteia_*` per
instance, so this needed no new wasm import and no compiler change.
`rt/runjs.mjs` publishes it identically, so both targets read the same
arguments.

**Host body.** A host that publishes nothing gives a program zero
arguments: `args-count` answers 0 and `args-list` answers `()`, on a
browser page as much as under a runner invoked without `--`. It is
`args-ref` out of range that raises, and it raises by name — an
argument the caller believed was there and is not should stop the run
at the point of the mistake, not read back as `#f`.

```
procedure: (args-count)   (args-list)   (args-ref i)

func -> int   /   func -> list   /   func -> int -> string
```
How many arguments the host published, all of them as a list of
strings, and the `i`th one.

### Hashtables

Hash tables with `eq?` or `equal?` keys. `make-hashtable` takes a
hash procedure and an equivalence, or use the `eq`/`equal` shorthands;
`hashtable-ref` requires a default value:
```scheme
(define ht (make-eq-hashtable))               ; also make-eqv-hashtable
(define eqht (make-hashtable equal-hash equal?)) ; equal? keys
(hashtable-set! ht 'name "Alice")
(hashtable-ref ht 'name #f)                   ; => "Alice"  (#f if absent)
```

```
procedure: (make-eq-hashtable)

func -> hashtable
```
A new hashtable with `eq?` keys (`make-eqv-hashtable` for `eqv?`).

```
procedure: (make-hashtable hash equiv)

func -> procedure -> procedure -> hashtable
```
A new hashtable with a custom hash procedure and equivalence, e.g.
`(make-hashtable equal-hash equal?)`.

```
procedure: (hashtable-set! ht key value)

func -> hashtable -> any -> any -> void
```
Associate `key` with `value`.

```
procedure: (hashtable-ref ht key default)

func -> hashtable -> any -> any -> any
```
The value for `key`, or `default` if absent. The default is required.

```
procedure: (hashtable-contains? ht key)

func -> hashtable -> any -> boolean
```
Whether `key` is present.

```
procedure: (hashtable-delete! ht key)

func -> hashtable -> any -> void
```
Remove `key` if present.

```
procedure: (hashtable-update! ht key proc default)

func -> hashtable -> any -> procedure -> any -> void
```
Set `key` to `(proc current)`, using `default` as the current value when
`key` is absent.

```
procedure: (hashtable-size ht)

func -> hashtable -> int
```
The number of entries.

```
procedure: (hashtable-keys ht)

func -> hashtable -> vector
```
A vector of all keys.

### Symbols and Gensym

Symbols are interned at compile time and at runtime via `string->symbol`. They are `eq?`-comparable. `gensym` takes a required prefix and appends a fresh counter:

```scheme
(gensym "var")  ; => a symbol named var0, var1, ... (prefix + counter)
```

```
procedure: (gensym prefix)

func -> string -> symbol
```
A fresh, uninterned-looking symbol: `prefix` plus a per-call counter.

```
procedure: (string->symbol s)

func -> string -> symbol
```
Intern `s` as a symbol (`eq?` to any other symbol of the same name).

```
procedure: (symbol->string sym)

func -> symbol -> string
```
The name of `sym` as a string.

### Error Handling

`guard`/`raise` and `dynamic-wind`:

`error` builds and raises a condition in one step —
`(error who message irritant ...)`; `guard` catches it and
`condition-message` / `error?` inspect it:

```scheme
(guard (e ((error? e)
           (display (condition-message e))))
  (error 'sqrt "negative argument" -1))

(dynamic-wind
  (lambda () (display "enter"))
  (lambda () (display "body"))
  (lambda () (display "exit")))
```

```
procedure: (error who message irritant ...)

func -> symbol -> string -> any -> ... -> never
```
Build a condition from `who`/`message`/`irritants` and raise it. Never
returns normally — catch it with `guard`.

```
procedure: (raise obj)

func -> any -> never
```
Raise `obj` as a condition to the nearest enclosing `guard`.

```
procedure: (error? c)

func -> any -> boolean
```
Whether `c` is an error condition.

```
procedure: (condition-message c)

func -> condition -> string
```
The message carried by a condition.

```
syntax: (guard (var clause ...) body ...)

any
```
Evaluate `body`; if it raises, bind the condition to `var` and dispatch
through the `cond`-style `clause`s (as in the example above). Evaluates
to the body's value, or the chosen clause's value on a raise.

```
procedure: (dynamic-wind before thunk after)

func -> procedure -> procedure -> procedure -> any
```
Run `(before)`, then `(thunk)`, then `(after)` — `after` runs even if
`thunk` escapes via a continuation. Returns `thunk`'s value.

### Continuations

`call/cc` captures **escape continuations only**—you can jump out of the current context but cannot re-enter a captured continuation. This is because Wasm exception handling (which implements continuations) supports upward jumps, not re-entrancy:

```scheme
(call/cc
  (lambda (escape)
    (for-each (lambda (x)
                (when (zero? (remainder x 7))
                  (escape x)))       ; jump out with the first hit
              '(1 2 3 7 14 21))))
; => 7
```

Do not attempt to call a captured continuation multiple times; the second call will trap.

```
procedure: (call/cc proc)

func -> procedure -> any
```
Call `(proc k)` where `k` is an **escape** continuation: invoking `(k v)`
returns `v` from the `call/cc` form. `call-with-current-continuation` is
the same procedure under its full name. `k` is one-shot and upward-only.

## JavaScript FFI

The `(web js)` library provides the bridge to JavaScript. Scheme closures automatically become callable JS functions via the `->js` procedure and the internal `$jscb` callback protocol.

### Exports and Usage

```
procedure: (js-ref? v)

func -> any -> boolean
```
Test whether `v` is a JS reference (externref).

```
procedure: (js-global)

func -> *jsObject globalThis
```

```
procedure: (js-undefined)

func -> *jsObject undefined
```

```
procedure: (js-eq? a b)

func -> *jsObject -> *jsObject -> boolean
```
JS identity: `a === b`.

```
procedure: (js-truthy? v)

func -> *jsObject -> boolean
```
JS truthiness of `v`.

```
procedure: (js-get obj name)

func -> *jsObject -> string -> *jsObject
```
Read a property: `obj[name]`.

```scheme
(js->number (js-get (js-eval "[10,20,30]") "length"))
=> 3
```

```
procedure: (js-set! obj name value)

func -> *jsObject -> string -> any -> void
```
Write a property: `obj[name] = value`.

```
procedure: (js-call f thisval args ...)

func -> *jsObject -> *jsObject -> any -> ... -> *jsObject
```
Apply a function: `f.apply(thisval, [args ...])`.

```
procedure: (js-method obj name args ...)

func -> *jsObject -> string -> any -> ... -> *jsObject
```
Call a method: `obj[name](args ...)`.

```
procedure: (js-new ctor args ...)

func -> *jsObject -> any -> ... -> *jsObject
```
Construct: `new ctor(args ...)`.

```
procedure: (js-index obj i)

func -> *jsObject -> int -> *jsObject
```
Index: `obj[String(i)]`.

```
procedure: (string->js s)

func -> string -> *jsObject
```
Convert a Scheme string to a JS string.

```
procedure: (js->string r)

func -> *jsObject -> string
```
Convert a JS string to a Scheme string.

```scheme
(js->string (js-eval "'ab'+'c'"))
=> "abc"
```

```
procedure: (number->js x)

func -> number -> *jsObject
```
Convert a Scheme number to a JS number.

```
procedure: (js->number r)

func -> *jsObject -> number
```
Convert a JS number to a Scheme number — fixnum if in range, flonum otherwise.

```
procedure: (->js v)

func -> any -> *jsObject
```
Convert any Scheme value to JS: closures become functions; `#t` / `#f` / `()`
map to their JS equivalents.

```
procedure: (js-eval code)

func -> string -> *jsObject
```
Evaluate JavaScript in the global scope: `eval(code)`.

```scheme
(js->number (js-eval "40+2"))
=> 42
```

### Closures as Functions

Scheme closures automatically convert to callable JS functions:

```scheme
(define callback (lambda (x) (+ x 1)))
(js-set! (js-global) "myCallback" (->js callback))
; now JS can call globalThis.myCallback(5), which calls the Scheme closure
```

The host-side bridge (`rt/jsbridge.mjs`, used by `rt/run.mjs` and `rt/web.mjs`) holds the closure as an opaque reference and invokes the exported `$jscb` when JS calls it, marshaling arguments and the return value through dedicated imports. Error handling: if the closure raises an error, the exception is caught and `undefined` is returned.

### Example: DOM Manipulation

```scheme
(import (web js) (web dom))

(define el (query-selector "#myButton"))
(add-event-listener! el "click"
  (lambda (event)
    (console-log "clicked")))
(js-method el "setAttribute" "disabled" "true")
```

## DOM

The `(web dom)` library wraps the DOM. A DOM node is a `*domElement`
(a `*jsObject` under the hood); most mutators return `void` and are
called for their effect on the tree.

```
procedure: (window)

func -> *jsObject
```
Return `globalThis`.

```
procedure: (document)

func -> *jsObject
```
Return `globalThis.document`.

```
procedure: (body)

func -> *domElement
```
Return `document.body`.

```
procedure: (get-element-by-id id)

func -> string -> *domElement
```
`document.getElementById(id)`. Answers a falsy handle when nothing has
the id.

```
procedure: (need-element-by-id id)

func -> string -> *domElement
```
The same lookup, insisting: it raises, naming the id, when nothing has
it. Reach for this wherever a missing element means the page is not the
one you wrote — a falsy handle otherwise travels on into whatever was
going to be written and surfaces from the host as a complaint about
setting a property of `null`, which names neither the id nor the lookup.

```
procedure: (query-selector sel)

func -> string -> *domElement
```
`document.querySelector(sel)` — the first match for the CSS selector.

```
procedure: (create-element tag)

func -> string -> *domElement
```
`document.createElement(tag)` — a new, unattached element.

```
procedure: (make-text s)

func -> string -> *domElement
```
`document.createTextNode(s)` — a new text node.

```
procedure: (append-child! parent child)

func -> *domElement -> *domElement -> void
```
Append `child` as the last child of `parent`.

```
procedure: (replace-child! parent new old)

func -> *domElement -> *domElement -> *domElement -> void
```
Replace `old` with `new` among `parent`'s children.

```
procedure: (insert-before! parent new ref)

func -> *domElement -> *domElement -> *domElement -> void
```
Insert `new` into `parent` just before the existing child `ref`.

```
procedure: (remove-child! parent child)

func -> *domElement -> *domElement -> void
```
Remove `child` from `parent`.

```
procedure: (remove-all-children! el)

func -> *domElement -> void
```
Remove every child of `el`, leaving it empty.

```
procedure: (set-inner-html! el s)

func -> *domElement -> string -> void
```
Set `el.innerHTML = s`.

```
procedure: (inner-text el)

func -> *domElement -> string
```
Read `el.innerText` as a Scheme string.

```
procedure: (set-text! el s)

func -> *domElement -> string -> void
```
Set `el.textContent = s`.

```
procedure: (set-attribute! el name v)

func -> *domElement -> string -> string -> void
```
Set the attribute `name` to `v` on `el`.

```
procedure: (set-style! el prop v)

func -> *domElement -> string -> string -> void
```
Set the CSS property `prop` to `v` on `el.style`.

```
procedure: (computed-style el name)

func -> *domElement -> string -> string
```
The resolved computed value of style property `name` on `el`, as a string
(`window.getComputedStyle(el)[name]`).

```scheme
(computed-style el "fontFamily")
=> "\"Inter\", sans-serif"
```

```
procedure: (computed-px el name fallback)

func -> *domElement -> string -> number -> number
```
The same value parsed as pixels — `"28.5px"` → `28.5`. Anything
`parseFloat` rejects (`"normal"`, `"auto"`, and the like yield `NaN`)
takes `fallback` instead.

```scheme
(computed-px el "lineHeight" 24.0)
```

```
procedure: (add-event-listener! el event handler)

func -> *domElement -> string -> procedure -> void
```
Attach `handler` for `event` (e.g. `"click"`). `handler` is a Scheme
procedure called with the event as a `*jsObject`.

```
procedure: (console-log x)

func -> any -> void
```
`console.log(x)`; non-string values are rendered with `write` first.

```
procedure: (alert s)

func -> string -> void
```
Show a browser alert dialog with message `s`.

## Reactivity

The `(web reactive)` library implements fine-grained reactive updates: signals hold values, effects observe them, and dependency tracking is automatic. A `*signal` is a reactive cell; a `*effect` is a live observer.

### Procedures

```
procedure: (signal init)

func -> any -> *signal
```
Create a signal holding `init`.

```
procedure: (signal-ref s)

func -> *signal -> any
```
Read the current value. Called inside an `effect`, it subscribes that
effect to `s`.

```
procedure: (signal-set! s v)

func -> *signal -> any -> void
```
Set the value to `v` and rerun observing effects. A write `eqv?` to the
current value is a no-op.

```
procedure: (signal-update! s f)

func -> *signal -> procedure -> void
```
Set the value to `(f current-value)`.

```
procedure: (effect thunk)

func -> procedure -> *effect
```
Run `thunk` now, tracking every signal it reads, and rerun it whenever
one of those signals changes. Returns the effect handle.

```
procedure: (on-cleanup thunk)

func -> procedure -> void
```
Register `thunk` to run at the end of the current effect's run —
before that effect's next run, or when it is disposed, whichever comes
first. This is how an effect releases what it acquired: the run that
opened a socket registers the thunk that closes it, and the close
happens before the next open.

Several registrations run in reverse order of registration, and an
effect's children are cleaned up before the effect itself. A `root`
body may register directly too; those thunks run when the root's
disposer fires.

That order covers the thunks of the tree being released, and nothing
else. A cleanup is ordinary code: one that writes a signal or disposes
another effect runs that other effect's cleanups — and its next body —
right there, between two thunks of this release. Keep cleanups to
releasing what the run acquired and the order above is the whole
story; drive the rest of the program from one and the interleaving is
yours to reason about.

Releasing a tree is one transaction. If a cleanup raises, every other
cleanup in that tree — the failing thunk's siblings, its owner's own,
and the rest of the subtree — still runs, and the first condition is
re-raised once they are all done, so a failing release cannot strand
what the others were going to free. On a rerun that also ends the
rerun: the new body does not run, and the condition comes out of the
write that triggered it.

Called with no run to end it is an error by name: outside every
effect, and from inside a cleanup, which is itself the end of a run.
An `effect` or `root` created inside a cleanup is a new run, though,
and its body may register normally.

Under `batch`, a condition raised by a cleanup surfaces where the
reruns happen — out of the `batch` call, not out of the `signal-set!`
that queued them.

```
procedure: (dispose-effect! e)

func -> *effect -> void
```
Stop effect `e` and dispose the effects it owns, running their
cleanups and then its own; it will not rerun again. A cleanup that
raises does not stop the others: the whole tree is released first and
the first condition is re-raised afterwards.

```
procedure: (root thunk)

func -> procedure -> pair
```
Run `thunk` under a fresh detached owner, so effects created inside
survive reruns of any enclosing effect. Returns `(result . dispose)` —
`car` is `thunk`'s value, `cdr` a thunk that disposes the whole tree.

```
procedure: (batch thunk)

func -> procedure -> any
```
Run `thunk`, coalescing all its signal writes into a single effect
rerun at the end. Returns `thunk`'s value.

```
procedure: (untracked thunk)

func -> procedure -> any
```
Run `thunk` without subscribing the current effect to any signal it
reads. Returns `thunk`'s value.

Behavior, end to end:

```scheme
(define c (signal 0))
(define d (signal 0))
(effect (lambda () (signal-set! d (* 2 (signal-ref c)))))
(signal-ref d)                      ; => 0   (ran once at creation)
(signal-set! c 5)
(signal-ref d)                      ; => 10  (effect reran)
(batch (lambda () (signal-set! c 100) 'done))  ; => done
(untracked (lambda () (signal-ref c)))          ; => 100
```

### Signals

A signal holds a value and notifies observers when it changes:

```scheme
(define count (signal 0))
(signal-ref count)              ; read current value
(signal-set! count 5)           ; set value
(signal-update! count (lambda (v) (+ v 1)))  ; update via a function
```

Same-value writes (detected with `eqv?`) do not trigger observers.

### Effects

An effect runs a thunk and automatically tracks which signals it reads:

```scheme
(define count (signal 0))
(define doubled (signal 0))

(effect (lambda ()
  (let ((c (signal-ref count)))
    (signal-set! doubled (* c 2)))))

(signal-set! count 5)  ; effect reruns, doubled becomes 10
```

When a signal the effect reads changes, the effect reruns. Re-subscription is automatic.

### Batching

`batch` coalesces multiple signal updates into one effect rerun:

```scheme
(batch (lambda ()
  (signal-set! count 1)
  (signal-set! total 10)))
; effects run once, not twice
```

### Effect Ownership

Effects created inside an effect are *owned* by that effect. When the owner reruns, its children are disposed (run to completion, then marked dead) and recreated fresh:

```scheme
(effect (lambda ()
  (let ((filter (signal-ref current-filter)))
    (effect (lambda ()
      ;; this inner effect dies when the outer one reruns
      (display (signal-ref data)))))))
```

This prevents stale inner effects from firing after the outer one changes context.

### Untracked and Root

`untracked` reads signals without subscribing:

```scheme
(effect (lambda ()
  (let ((x (signal-ref count)))        ; subscribed
    (let ((y (untracked (lambda ()
      (signal-ref hidden)))))          ; not subscribed
      ...))))
```

`root` creates a detached owner—effects inside survive outer reruns and die only via explicit disposal:

```scheme
(let ((r (root (lambda ()
  (effect (lambda () ...))
  (signal 0)))))
  (car r))  ; the return value
; (cdr r)  ; the dispose thunk
```

This is useful for components that outlive a single effect.

## Templates

The `(web sx)` macro builds reactive DOM templates. Static structure is built once at expansion time; dynamic holes become effects that update in place.

### Procedures

`sx` is a macro; `sx-mount` and `sx-list` are procedures.

```
syntax: (sx template)

template -> *domElement
```
Expand a quasiquoted markup template into a live DOM fragment: static
structure is built once; each `,`-unquote becomes an effect (or, under
an `on-*` attribute, an event listener) that updates in place. Returns
the root element.

```
procedure: (sx-mount container node)

func -> *domElement -> *domElement -> *domElement
```
Append `node` (typically an `sx` fragment) as a child of `container` and
return `node`.

```
procedure: (sx-list thunk render [key])

func -> procedure -> procedure -> procedure -> *domElement
```
Build a host element whose children track a dynamic list. `(thunk)`
yields the current items; `(render item)` yields a node per item.
Without `key` the rebuild is naive (clear + re-render); with a `key`
procedure, a surviving key keeps its node, effects and DOM state and only
moves. Returns the host element.

### The `sx` Macro

```scheme
(import (web sx) (web reactive) (web dom))

(define count (signal 0))

(sx (div
  (@ (id "counter") (class "app"))
  (span ,(signal-ref count))
  (button (@ (on-click ,(lambda _ (signal-update! count (lambda (v) (+ v 1))))))
    "+")))
```

The macro expands into a call to `$sx-build`, which:
1. **Quotes the template**: the static structure is built once
2. **Extracts holes**: unquotes become thunks rerun inside effects
3. **Distinguishes listeners**: `on-*` attribute holes are evaluated once and attached as listeners; all other holes are effects that update

### Hole Types

- **Listener holes** (`on-click`, `on-change`, etc.): The unquoted expression is evaluated once at build time and attached as an event listener
- **Attribute holes** (other attributes): Dynamic expressions become effects that update the attribute value
- **Child holes**: Dynamic expressions become effects that update the child text node or element

### Mounting

`sx-mount` appends a template to a container:

```scheme
(sx-mount (get-element-by-id "app")
  (sx (div (h1 "Hello"))))
```

Returns the root element.

### Dynamic Lists

`sx-list` renders a dynamic list of items. Without a key, the rebuild is naive (clear and re-render):

```scheme
(define items (signal '("apple" "banana")))

(sx-mount container
  (sx-list (lambda () (signal-ref items))
           (lambda (item)
             (sx (li ,item)))))
```

With a key function, nodes are keyed by identity, so moving items preserves their DOM state and effects:

```scheme
(define todos (signal '()))  ; list of (id . title) pairs

(sx-mount container
  (sx-list (lambda () (signal-ref todos))
           (lambda (todo)
             (sx (li (@ (id ,(number->string (car todo))))
                   (span ,(cdr todo)))))
           car))  ; key function: use car (the id) as the key
```

### The Write-Only DOM Principle

The DOM is treated as a write-only surface—never read from it to get state. Use signals to hold state; let the template projection from signals to DOM:

```scheme
;; Good: state in signal, DOM projects from it
(define text (signal ""))
(sx (input (@ (on-input ,(lambda (e)
  (signal-set! text (js->string (js-get (js-get e "target") "value"))))))))

;; Bad: reading from the DOM defeats reactivity
(let ((val (js->string (js-get (query-selector "input") "value"))))
  ...)
```

## HTML and CSS as Data

Two build-time libraries render s-expressions to markup and styles — the pure-function duals used to generate this very site (see `site/*.ss`). Neither touches the DOM; both just return strings.

### `(web html)`: SXML → HTML

An SXML node is `(tag (@ (attr value) ...) child ...)`, where a child is a string (escaped on emit) or another node; `(raw s)` inserts a string verbatim.

```
procedure: (sxml->html node)

func -> sxml -> string
```
Render one SXML node to an HTML string; text content is escaped.

```scheme
(sxml->html '(div (@ (class "a")) "hi " (b "x") " <>&"))
=> "<div class=\"a\">hi <b>x</b> &lt;&gt;&amp;</div>"
```

```
procedure: (html->document node)

func -> sxml -> string
```
Like `sxml->html`, but prefixed with `<!DOCTYPE html>` — a full page.

```
procedure: (html-escape s)

func -> string -> string
```
Escape `&`, `<`, `>` for use as text content.

```scheme
(html-escape "a <b> & \"c\"")
=> "a &lt;b&gt; &amp; \"c\""
```

```
procedure: (raw s)

func -> string -> raw
```
Wrap `s` so `sxml->html` emits it **unescaped** — for pre-rendered HTML
or entities like `&nbsp;`.

```
procedure: (raw? x)

func -> any -> boolean
```
Test whether `x` is a `raw` marker.

### `(web css)`: Rule List → CSS

A stylesheet is a list of rules; a rule is `(selector (prop value ...) ...)`. Selectors are symbols (element names) or strings (anything with `.`/`#`/`:`/space). Values: exact integers pass through, strings are literal, unit forms like `(em 0 92)` → `0.92em` and `(var ink)` → `var(--ink)`; `@media` / `@keyframes` / `@supports` nest rules.

```
procedure: (css->string rules)

func -> list -> string
```
Render a rule list to a CSS string.

```scheme
(css->string '((body (margin 0) (color (var ink)))
               (".nav a" (font-size (em 0 92)))))
=> "body{margin:0;color:var(--ink);}.nav a{font-size:0.92em;}"
```

```
procedure: (num->css n)

func -> number -> string
```
Render one numeric CSS scalar — an exact integer, or a string passed
through. Used internally by the unit forms.

```
procedure: (palette->root palette)

func -> alist -> list
```
Turn a palette alist `((name value) ...)` into the `:root` rule that
declares each colour as a custom property — one Scheme binding then names
a colour for both code and CSS. The result is a single rule, ready to
`css->string` at the head of the stylesheet.

```scheme
(palette->root '((ink "#14203a") (lapis "#1550c4")))
=> (:root (--ink "#14203a") (--lapis "#1550c4"))
```

### `(web component)`: Element-Attached CSS

The React lesson taken at build time: write the styles *on* the element,
where the values are ordinary bindings (change one, change every use), and
let the library intern each distinct style set to one generated class —
nine identical cards cost one rule. The registry fills while the page is
*built* and renders once, so there is no css-in-js runtime tax; anything
genuinely dynamic belongs to signals and CSS variables, not here.

```
syntax: (define-component (name . args) (style decl ...) (tag kid ...))
```
Bundle a component's markup template and its style set in one form.
`name` doubles as the class prefix; each `arg` is a template hole. The
`(tag kid ...)` body is **implicitly quasiquoted** — an unquote `,x` is a
hole, and `,@xs` splices a list of children — so `tag` names the element
and the kids fill it. A leading `(@ ...)` kid passes extra attributes
through. A `decl` is either a plain declaration `(prop value ...)` or one
of three nested sub-forms:

- `(:hover decls ...)` — a pseudo-class rule (any `:`-led symbol).
- `("h3" decls ...)` — a descendant selector under the component's class.
- `(@media 42 items ...)` — a `max-width` breakpoint, the number in `em`.
  The block holds the same `item` shapes as the top level: plain
  declarations (applied to the component's own class) *and*
  `("sel" ...)` / `(:pseudo ...)` sub-rules — so a component's
  responsive shape, including how its descendants reflow at a
  breakpoint, travels with it. For example
  `(@media 64 (".feature" (grid-template-columns "1fr")))` narrows a
  descendant grid to one column below 64 em.

Equal style sets share one interned class, so identical components emit a
single rule.

```scheme
(define-component (card title . body)
  (style (background (var bg2)) (border (px 1) solid (var line))
         (border-radius (px 10)) (padding (em 1 10) (em 1 20))
         ("h3" (margin 0 0 (em 0 40)) (color (var lapis)) (font-weight 600))
         ("p" (margin 0) (color (var dim))))
  (div (h3 ,title) (p ,@body)))
```

```
procedure: (styled tag name style-set kid ...)

func -> symbol -> symbol -> list -> any … -> sxml
```
The procedural form underneath `define-component`: intern `style-set`
under prefix `name`, and return the `tag` node carrying the generated
`class` — a leading `(@ ...)` kid contributes the element's other
attributes. You rarely call this directly.

```
procedure: (styled-css)

func -> list
```
Every interned rule so far, in registration order, as a `(web css)` rule
list. Append it to the page's stylesheet before rendering:

```scheme
(css->string (styled-css))   ; the element-attached styles
```

## React Interop

The `(web react)` library embeds Goeteia components into a React app.

```
procedure: (react-component name mount)

func -> string -> procedure -> void
```
Register a component factory under `name`. `mount` is called
`(mount container props)` — `container` is a DOM element React created,
`props` a JS object — and may return a dispose thunk.

```
procedure: (props-ref props name)

func -> *jsObject -> string -> any
```
Read prop `name` from the `props` object, or `#f` if absent.

### Scheme Side: `react-component`

```scheme
(import (web react) (web sx) (web reactive) (web dom))

(react-component "Counter"
  (lambda (container props)
    ;; container: a DOM element React created for you
    ;; props: JS object with prop values
    
    (let ((start (or (props-ref props "start") 0)))
      (define count (signal start))
      (sx-mount container
        (sx (div
          (span ,(signal-ref count))
          (button (@ (on-click ,(lambda _ (signal-update! count 1+))))
            "+"))))
      
      ;; return a dispose thunk (optional)
      (lambda ()
        (display "unmounting")))))
```

`react-component` registers a factory on `globalThis.__goeteia[name]`. The factory takes `(container, props)` and returns a dispose thunk.

### Props

`props-ref` reads a prop by name, returning the JS value or `#f` if absent:

```scheme
(define value (props-ref props "value"))
(if value (do-something (js->string value)))
```

### JS Side: `goeteiaComponent`

In your React app:

```javascript
import { loadGoeteia } from './rt/web.mjs';
import { goeteiaComponent } from './rt/react.mjs';

loadGoeteia('widgets.wasm');

const Counter = goeteiaComponent(React, 'Counter');

export default function App() {
  return <Counter start={10} />;
}
```

`goeteiaComponent(React, name, opts?)` wraps a Goeteia factory in a React component. Props flow in; the component remounts when any prop changes (via `Object.values(props)` in the `useEffect` dependency array). The dispose thunk runs on unmount.

## 3D and WebGL

A layered graphics stack, and it lives under `gfx`, not `web`. At the base, `(gfx gl)` speaks WebGL 2 through a command buffer and `(gfx glsl)` writes shaders as s-expressions; `(gfx mat)` and `(gfx mesh)` add math and geometry; `(gfx fx)` ties them into a self-wiring harness (the practical entry point); `(gfx scene)` makes scenes declarative; `(gfx gltf)` loads assets and `(gfx glb)` writes them back out; `(gfx collide)` handles game collision. Throughout, the frame is described as data, built once, and the rendering surface is write-only — bridge traffic is O(changes), never O(frames).

### Linear Staging Memory

Every compiled module exports one growable linear wasm memory named
`memory`, which the host also sees as `globalThis.__goeteia_mem`. Scheme
writes a frame's worth of numeric data (vertices, particles) into it, and
the host reads the *same bytes* zero-copy as a typed array (a
`Float32Array` over `exports.memory.buffer`) — collapsing tens of
thousands of bridge calls into one. It is an export, not an import, so
older hosts still instantiate newer modules. `(gfx gl)` below is built on
it; the byte-level accessors are internal primitives.

### `(gfx gl)`: Raw WebGL via a Command Buffer

For full control with no Three.js, `(gfx gl)` speaks WebGL through a *command buffer*: Scheme encodes a frame's GL commands as words in the shared linear memory (the staging-memory primitives, `%mem-*`) and one bridge call replays them all. Vertex data uploads zero-copy from the same memory. Resources—programs, buffers, uniform locations—are JS objects, so they live in a slot table set up once at init; commands refer to slot numbers.

```scheme
(import (gfx gl) (gfx glsl))

(gl-attach! (get-element-by-id "c"))
(gl-program! 0 vertex-shader fragment-shader)   ; slot 0
(gl-buffer! 1)                                   ; slot 1
(cmd-region! 0)

(define (frame!)
  (cmd-begin!)
  (cmd-viewport! 0 0 800 600)
  (cmd-clear! 0.07 0.08 0.12 1.0)
  (cmd-use-program! 0)
  (cmd-bind-buffer! 1)
  (cmd-buffer-data! POS (* 8 N))                 ; zero-copy from staging memory
  (cmd-vertex-attrib! 0 2 0 0)
  (cmd-draw-arrays! GL-POINTS 0 N)
  (cmd-flush!))                                   ; ONE bridge call per frame
```

The JS replayer is embedded in the library as a string (injected once
with `js-eval`), so there is no host-side file to ship. See
`examples/gl-particles.html`—10,000 particles, one bridge call per frame.

#### Setup (once)

Resources are real JS objects held in a slot table; you create them
once and refer to them later by slot number.

```
procedure: (gl-attach! canvas)

func -> *domElement -> *jsObject
```
Inject the replayer (via `js-eval`), create a `webgl` context on
`canvas`, and return the replayer handle. Side effect: installs
`globalThis.__goeteia_gl` and binds the module's staging memory.

```
procedure: (gl-program! slot vs fs)

func -> int -> string -> string -> void
```
Compile the vertex-shader source `vs` and fragment-shader source `fs`,
link them into a program, and store it in `slot`. Side effect: throws
(from JS) if a shader fails to compile or the program fails to link.

```
procedure: (gl-buffer! slot)

func -> int -> void
```
Create an `ARRAY_BUFFER` and store it in `slot`.

```
procedure: (gl-uniform! slot pslot name)

func -> int -> int -> string -> void
```
Look up uniform `name` in the program at slot `pslot` and store its
location in `slot`.

#### Per-frame commands

Each `cmd-*` encodes one word-aligned command into the staging memory at
the current write pointer; nothing touches WebGL until `cmd-flush!`.

```
procedure: (cmd-region! base)

func -> int -> void
```
Set the staging-memory byte offset where the command stream is written.

```
procedure: (cmd-begin!)

func -> void
```
Reset the write pointer to the region base — start a new frame.

```
procedure: (cmd-clear! r g b a)

func -> number -> number -> number -> number -> void
```
Encode `clearColor(r,g,b,a)` followed by a color+depth `clear`.

```
procedure: (cmd-use-program! slot)

func -> int -> void
```
Encode `useProgram` of the program in `slot`.

```
procedure: (cmd-bind-buffer! slot)

func -> int -> void
```
Encode `bindBuffer(ARRAY_BUFFER, …)` of the buffer in `slot`.

```
procedure: (cmd-buffer-data! offset bytes)

func -> int -> int -> void
```
Encode `bufferData` uploading `bytes` bytes from staging memory at byte
`offset` — zero-copy, since the data already lives in that memory.

```
procedure: (cmd-vertex-attrib! loc size stride offset)

func -> int -> int -> int -> int -> void
```
Encode `enableVertexAttribArray(loc)` + `vertexAttribPointer(loc, size,
FLOAT, false, stride, offset)`.

```
procedure: (cmd-uniform1f! slot x)

func -> int -> number -> void
```
Encode `uniform1f` writing `x` to the uniform location in `slot`.

```
procedure: (cmd-uniform4f! slot x y z w)

func -> int -> number -> number -> number -> number -> void
```
Encode `uniform4f` writing `(x,y,z,w)` to the uniform location in `slot`.

```
procedure: (cmd-draw-arrays! mode first count)

func -> int -> int -> int -> void
```
Encode `drawArrays(mode, first, count)`; `mode` is a `GL-*` constant.

```
procedure: (cmd-viewport! x y w h)

func -> int -> int -> int -> int -> void
```
Encode `viewport(x, y, w, h)`.

```
procedure: (cmd-flush!)

func -> void
```
The single bridge call: replay every command encoded since `cmd-begin!`,
issuing the real `gl.*` calls for the whole frame at once.

#### Draw-mode constants

Integer enums for the `mode` argument of `cmd-draw-arrays!`:
`GL-POINTS` (0), `GL-LINES` (1), `GL-TRIANGLES` (4),
`GL-TRIANGLE-STRIP` (5).

#### WebGL 2 and more resources

The context is WebGL 2 with a WebGL 1 fallback (`getContext('webgl2') ||
getContext('webgl')`). Beyond `gl-buffer!`, the slot table holds textures,
render targets, vertex arrays, uniform buffers, and transform-feedback
programs — each created once and referred to by slot.

```
procedure: (gl-texture! slot)

func -> int -> void
```
Create a 2D texture (LINEAR-mipmap sampling, clamp-to-edge) in `slot`.

```
procedure: (gl-texture-upload! slot src [premul])

func -> int -> *jsObject -> boolean -> void
```
Upload an image/canvas/bitmap `src` into the texture in `slot` and
generate mipmaps. A true `premul` premultiplies alpha (for sprite sheets).

```
procedure: (gl-texture-data! slot base w h)

func -> int -> int -> int -> int -> void
```
Upload `w`×`h` raw RGBA bytes from staging memory at `base` into the
texture — a texture computed in Scheme (a procedural normal map, a
lookup table).

```
procedure: (gl-cubemap! slot base dim)

func -> int -> int -> int -> void
```
Build a cube map from six `dim`×`dim` RGBA faces laid out consecutively at
`base` (order +x −x +y −y +z −z).

#### Indexed and instanced drawing

An element buffer draws indexed meshes; a divisor plus
`drawElementsInstanced` draws thousands of copies in one call.

```
procedure: (cmd-bind-index! slot)

func -> int -> void
```
Encode `bindBuffer(ELEMENT_ARRAY_BUFFER, …)` of the buffer in `slot`.

```
procedure: (cmd-index-data! offset bytes)

func -> int -> int -> void
```
Encode `bufferData` uploading `bytes` of `u16` indices from staging
memory at `offset`.

```
procedure: (cmd-draw-elements! mode count)

func -> int -> int -> void
```
Encode `drawElements(mode, count, UNSIGNED_SHORT, 0)`.

```
procedure: (cmd-attrib-divisor! loc n)

func -> int -> int -> void
```
Encode `vertexAttribDivisor(loc, n)` — `n=1` advances attribute `loc`
once per instance instead of per vertex.

```
procedure: (cmd-draw-elements-instanced! mode count instances)

func -> int -> int -> int -> void
```
Encode `drawElementsInstanced` — one draw for `instances` copies. See
`examples/fx-forest.html`: 8,000 trees, one call.

#### More uniforms

Beyond `cmd-uniform1f!`/`cmd-uniform4f!`: `cmd-uniform1i!` (samplers,
integers), `cmd-uniform2f!`, `cmd-uniform3f!` for vectors, and matrices:

```
procedure: (cmd-uniform-matrix4! slot m)

func -> int -> vector -> void
```
Encode `uniformMatrix4fv` writing the 16-element column-major mat4 `m`
(from `(gfx mat)`) to the location in `slot`.

```
procedure: (cmd-uniform-matrices! slot ms)

func -> int -> vector -> void
```
Encode `uniformMatrix4fv` for an array of mat4s — a `mat4[N]` uniform,
e.g. skinning joint matrices.

#### Render targets

A framebuffer renders into a texture instead of the canvas — the door to
shadows, post-processing, reflections.

```
procedure: (gl-target! slot tslot w h [depth-only?])

func -> int -> int -> int -> int -> boolean -> void
```
Create an offscreen target: a framebuffer in `slot` whose color texture
lands in `tslot`. A true `depth-only?` makes a depth texture with no color
buffer — a shadow map. Also `gl-target-hdr!` (RGBA16F, values past 1.0
survive, for bloom), `gl-target-msaa!` (multisampled; `cmd-resolve!` blits
it down), and `gl-cube-target!` (six faces around a point, for point-light
shadows).

```
procedure: (cmd-bind-target! slot)   /   (cmd-bind-canvas!)

func -> int -> void   /   func -> void
```
Direct subsequent draws into the target in `slot`, or back to the canvas.

#### Textures, depth, and blending in the frame

```
procedure: (cmd-bind-texture! unit slot)

func -> int -> int -> void
```
Bind the texture in `slot` to sampler `unit` (0, 1, …). `cmd-bind-cubemap!`
binds a cube map; `cmd-unbind-texture!` / `cmd-unbind-cubemap!` clear a
unit — needed before rendering *into* a target you also sample, or strict
drivers reject the feedback loop.

```
procedure: (cmd-depth! on?)

func -> boolean -> void
```
Enable or disable the depth test.

```
procedure: (cmd-blend! mode)

func -> symbol -> void
```
Set blending: `'alpha` (src-over), `'add` (additive glow), `'premul`
(premultiplied src-over), `'off` (opaque).

#### VAOs, uniform buffers, transform feedback (WebGL 2)

Three WebGL-2 facilities for scale. A **vertex array object** records an
attribute setup once and rebinds it with one command (`gl-vao!`,
`cmd-bind-vao!`, `cmd-unbind-vao!`). A **uniform buffer** shares per-frame
state across programs from one upload (`gl-ubo!`, `gl-uniform-block!`,
`cmd-bind-ubo!`, `cmd-ubo-data!`) — it needs the ESSL 3.00 dialect (see
below). A **transform-feedback program** captures a vertex shader's
outputs back into a buffer (`gl-tf-program!`, `cmd-tf-buffer!`,
`cmd-tf-begin!`, `cmd-tf-end!`): the GPU updates particle state with no
CPU in the loop (`examples/fx-gpu-particles.html`, 100,000 particles). All
three are wrapped by `(gfx fx)` below — most code never calls them
directly.

### `(gfx glsl)`: Shaders as S-Expressions

`glsl->string` renders a form list to GLSL source—the `(web css)` of shaders. Shaders are lists, so they compose with `append` and abstract with functions.

```
procedure: (glsl->string forms)

func -> list -> string
```
Render a list of GLSL forms to a GLSL source string.

```scheme
(glsl->string
 '((attribute vec2 p)
   (define (main) void
     (set! gl_Position (vec4 p (fl 0) (fl 1)))
     (set! gl_PointSize (fl 2)))))
=> "attribute vec2 p; void main() { gl_Position = vec4(p, 0.0, 1.0); gl_PointSize = 2.0; } "
```

Top-level forms: `attribute`/`uniform`/`varying`, `precision`, and `define` for functions. Statements: `local`, `set!`, `return`, `if`/`if-else`, `discard`. Expressions: `+ - * /` are infix, comparisons `< > <= >= ==`, anything else is a call; symbols pass through verbatim, so swizzles like `p.x` just work. Float literals use the whole-plus-hundredths convention—`(fl 2)` → `2.0`, `(fl 0 50)` → `0.5`, `(fl 1 25)` → `1.25`—so no Scheme flonum (and no printer noise) ever reaches the source.

#### More glsl: loops, arrays, and interface extraction

Beyond the core forms, `for` writes a counted loop — the shape kernel
sweeps (PCF shadows, blurs) need:

```scheme
(for (int i 0 (< i 3) (+ i 1))
  (set! acc (+ acc (texture2D u_src (+ uv (* i step))))))
=> "for (int i = 0; (i < 3); i = (i + 1)) { ... } "
```

Array uniforms declare a size — `(uniform (array mat4 32) u_joints)` —
and `(at u_joints i)` indexes them, for skinning.

The declarations are data, so the interface a program wires up comes from
the same list that rendered its source:

```
procedure: (glsl-attributes forms)   (glsl-uniforms forms)   (glsl-varyings forms)

func -> list -> alist
```
Extract the `attribute` / `uniform` / `varying` declarations in order —
`glsl-attributes` returns `(name type component-count)` triples,
`glsl-uniforms` `(name type)` pairs, `glsl-varyings` names. `(gfx fx)`
uses these to wire attribute locations, uniform slots, and
transform-feedback capture lists automatically.

#### The ESSL 3.00 dialect

The form language is dialect-neutral. `glsl->string` renders ESSL 1.00
(WebGL 1 style); `glsl300-vs->string` / `glsl300-fs->string` render the
*same forms* as `#version 300 es` — `attribute`→`in`, `varying`→`out`
(vertex) / `in` (fragment), `gl_FragColor`→a declared output,
`texture2D`/`textureCube`→the unified `texture()`. A new form,
`(uniform-block Name (T field) …)`, becomes a `std140` uniform block —
the syntax uniform buffers require, which 1.00 lacks. `fx-program3!` and
`fx-tf-program!` (below) compile through these.

### `(gfx mat)`: 3D Math

`vec3` and column-major `mat4` over plain flonum vectors — pure Scheme,
verified headlessly, its own range-reduced trig so both compiler hosts
emit identical bytes. A `mat4` is a 16-element vector, exactly what
`uniformMatrix4fv` (and `fx-uniform!`'s mat4 case) wants.

```
procedure: (v3 x y z)

func -> number -> number -> number -> vector
```
A 3-vector. Accessors `v3-x`/`v3-y`/`v3-z`; operations `v3-add`,
`v3-sub`, `v3-scale`, `v3-dot`, `v3-cross`, `v3-normalize`.

```
procedure: (m4-mul a b)

func -> vector -> vector -> vector
```
Multiply two mat4s — `(m4-mul a b)` transforms as `a` after `b`.
`m4-identity`, `m4-transform` (point through a matrix, w-divided).

```
procedure: (m4-perspective fovy aspect near far)   (m4-ortho l r b t near far)

func -> number -> number -> number -> number -> vector
```
Projection matrices. `m4-look-at eye center up` builds a view;
`m4-translate`, `m4-scale`, `m4-rotate-x/-y/-z`, `m4-from-quat` build
model transforms; `flsin`/`flcos`/`fltan` are the library's own trig.

```
procedure: (q-mul a b)   (q-conj q)   (q-neg q)   (q-dot a b)   (q-normalize q)

func -> vector -> vector -> vector   /   func -> vector -> vector
```
Quaternion algebra over 4-element vectors `#(x y z w)` — the shape
glTF stores node rotations in, and the shape `m4-from-quat` reads.

`q-mul` is the Hamilton product in the composition order the matrices
use: `R(q-mul a b)` = `R(a)` · `R(b)`, so `(q-mul q r)` turns `q` by
`r` expressed in **q's own frame**, which is what posing a joint by a
local twist means. It does not commute.

`q-conj` negates the vector part and keeps the scalar one; on a *unit*
quaternion that is the inverse rotation and `(q-mul q (q-conj q))` is
`#(0 0 0 1)`, while on a non-unit one the product is the squared norm.
`q-neg` negates *every* lane, and `q` and `(q-neg q)` are the **same**
rotation (the double cover) — which is why a track that must not take
the long way round flips a key whose dot with the previous one is
negative. `q-normalize` divides by the norm, answering the identity
rather than four NaNs for the zero quaternion, which is not a rotation
and has no direction to keep. `q-slerp a b t` interpolates two unit
quaternions along the shortest arc at a constant angular rate.

Like the rest of this library they assume flonum components: they are
the per-frame hot path, and a rotation read out of the node table is
flonum in every lane.

```
procedure: (m4-inverse m)

func -> vector -> vector
```
General 4×4 inverse (or `#f` if singular). With `m4-unproject inv-vp x y
z` it turns a cursor into a world-space ray — the basis of picking, with
`(gfx collide)`.

```
procedure: (m4-frustum-planes vp)   (sphere-in-frustum? planes c r)

func -> vector -> vector   /   func -> vector -> vector -> number -> boolean
```
Extract the six view-frustum planes from a view-projection, and test a
bounding sphere against them — conservative frustum culling. Pair with
`mesh-bounds`.

### `(gfx reflect)`: How Much of a Reflection Needs Drawing

A planar reflection re-renders the world into an offscreen target with
a mirrored camera, and almost always only a small part of that target
can ever be sampled — the pond, the floor, the pane covers a small
part of the screen. This library answers how much, as pure geometry:
no GL, no state.

The failure mode it exists to avoid is a **silently missing
reflection**: a rectangle one pixel too small reflects nothing there
and nothing reports it. So anything that cannot be projected
conservatively answers `#t`, rounding is outward only, and `#f` comes
back only when the footprint is provably not visible.

```
procedure: (reflect-plane-matrix plane-y)

func -> number -> vector
```
A mirror matrix about the horizontal plane `y = plane-y`, for building
the mirrored camera.

```
procedure: (reflect-range main-vp reflect-vp polys pad width height)

func -> vector -> vector -> list -> number -> number -> number -> any
```
`#f` to skip the pass, `#t` for the whole target, or `#(x y w h)` in
pixels with the origin at the **lower left**, matching `gl.scissor`
and `cmd-viewport!` — `(gfx sprite)` speaks the opposite convention.
`polys` is a list of flat world-space `x y z` vectors, one per
footprint, all on the plane `reflect-vp` already encodes; reflectors
on different planes are different calls. `width`/`height` are the
**target's**, not the canvas backing size, and must be positive
integers; `pad` is a non-negative number of pixels. Anything else is a
named error.

The polygons must already enclose the maximum displacement the
caller's shader applies. A pixel pad cannot recover geometry a wave
pushes into view, because padding happens after the footprint has been
clipped against the main view: a crest rising into frame from a
footprint already rejected contributes nothing. `pad` covers what
happens after projection — distorted sampling, filter taps.

```
procedure: (m4-crop-rect proj x y w h width height)

func -> vector -> number -> number -> number -> number -> number -> number -> vector
```
The projection restricted to that pixel rectangle, so the rectangle
becomes the whole of clip space. Its first use is culling the
reflection pass against the smaller frustum. Note that cropping the
projection and scissoring the pass are **alternatives**: cropping
while leaving the full viewport stretches the image.

### `(gfx mesh)`: Parametric Geometry

Positions, normals, indices generated in pure Scheme — a framework's
geometry classes without the framework. A mesh holds interleaved
`(x y z nx ny nz)` flonums (24 bytes/vertex, `mesh-lit-vs`'s layout) and
u16 indices.

```
procedure: (mesh-plane w d)   (mesh-box w h d)   (mesh-sphere r [segs rings])
           (mesh-cylinder r h [segs])   (mesh-torus R r [segs rings])

func -> number … -> *mesh
```
The generators. `mesh-heightmap w d nx nz f` builds terrain from any pure
height function `f`, with central-difference normals.

```
procedure: (mesh-write! m vbase ibase)

func -> *mesh -> int -> int -> void
```
Lay the vertices at `vbase` and indices at `ibase` in staging memory.
`mesh-vertex-bytes`/`mesh-index-bytes`/`mesh-index-count` size the buffers.
`mesh-write-uv!` (32-byte, adds uvs) and `mesh-write-tan!` (48-byte, adds
a tangent frame for normal mapping) are the wider layouts; `mesh-tangents`
and `mesh-bounds` (a bounding sphere) are the derived data.

**Ready-made programs.** `mesh-lit-vs`/`-fs` are glsl forms for one
directional light plus an ambient floor (uniforms `u_mvp`, `u_model`,
`u_light`, `u_color`, `u_ambient`). `mesh-tex-vs`/`-fs` add a texture,
`mesh-normal-vs`/`-fs` a tangent-space normal map, `mesh-pbr-vs`/`-fs`
Cook-Torrance PBR with the sky as an image-based light probe. They are
just data — compose or replace them.

### `(gfx fx)`: The Effects Harness

The practical entry point. A shader authored as `(gfx glsl)` forms
already declares its interface, so `fx` reads it back and does the
bookkeeping raw `(gfx gl)` leaves to you — attribute locations,
interleaved offsets, uniform slots, resource slot numbers,
staging-memory layout, the render loop. Slot numbers and staging memory
are owned by `fx` from `fx-init!` on.

```
procedure: (fx-init! canvas)

func -> *domElement -> void
```
Attach to `canvas` and reset the slot counter and staging heap (the
command region is bytes [0, 64KiB); `fx-alloc!` hands out what lies
above). Call once before any `fx-*` resource.

```
procedure: (fx-program! vs-forms fs-forms)

func -> list -> list -> *fx-program
```
Compile and link a program from vertex and fragment *forms*, binding
attribute locations from the vertex declarations and allocating a uniform
slot per declared uniform. `fx-program3!` compiles the ESSL 3.00 dialect
(for uniform blocks); `fx-tf-program!` makes a transform-feedback program,
capturing the vertex shader's varyings.

```
procedure: (fx-buffer!)   (fx-texture!)   (fx-ubo! bytes)   (fx-alloc! bytes)

func -> int   /   func -> int -> int
```
Allocate a resource slot (buffer, texture, uniform buffer) or a
byte range of staging memory. `fx-target!` / `fx-target-hdr!` /
`fx-target-msaa!` / `fx-cube-target!` create render targets as records
(`fx-target-texture` samples one; `fx-bind-target!` / `fx-bind-canvas!` /
`fx-bind-cube-face!` / `fx-resolve!` drive them).

```
procedure: (fx-use! prog buf-slot)

func -> *fx-program -> int -> void
```
Use `prog` and bind `buf-slot` as its vertex source, replaying each
declared attribute's pointer. `fx-use-instanced! prog buf inst` adds a
per-instance stream (attributes named `i_*`).

```
procedure: (fx-uniform! prog name . values)

func -> *fx-program -> symbol -> number … -> void
```
Set a uniform by name, dispatched on its declared type — `float`,
`vec2`/`3`/`4`, `sampler2D`/`samplerCube` (an integer unit), `mat4` (a
`(gfx mat)` matrix), or `(array mat4 N)` (a vector of matrices). Floats
may be fixnums; they are coerced.

```
procedure: (fx-mesh! m)

func -> *mesh -> *fx-mesh
```
Take a `(gfx mesh)` mesh, allocate its vertex and index buffers, and stage
its data — the upload dance every demo used to repeat by hand. Returns a
handle; the actual GPU upload is deferred to the first draw.

```
procedure: (fx-mesh-use! prog h)

func -> *fx-program -> *fx-mesh -> void
```
Bind handle `h` for drawing under `prog`, replaying the vertex pointers
and the index buffer, and performing the one-time lazy upload inside the
first frame that reaches it. Bind once, set uniforms, and draw many times.

```
procedure: (fx-mesh-draw! h)

func -> *fx-mesh -> void
```
Issue the indexed triangles for handle `h` (`fx-mesh-count` is its index
count; `fx-mesh?` tests the handle type).

```scheme
(define pillar (fx-mesh! (mesh-box 1.4 7.0 1.4)))
;; ... per frame: bind once, draw the pillar under each model matrix
(fx-mesh-use! lit-p pillar)
(fx-uniform! lit-p 'u_color 0.7 0.55 0.4 1.0)
(fx-mesh-draw! pillar)
```

```
procedure: (fx-loop! proc)

func -> procedure -> void
```
Run `proc` every animation frame with `(t dt)` in seconds, wrapped in
`cmd-begin!` … `cmd-flush!` and a canvas-sized viewport. `fx-ticks!` is
the bare timing pump (no GL); `fx-fullscreen!` / `fx-fullscreen-use!` /
`fx-fullscreen-draw!` make a full-screen fragment-shader effect (a
shadertoy) in a dozen lines.

```
procedure: (fx-init-input! [element])   (key-down? name)   (pointer-x)
           (pointer-down?)   (pointer-lock! )   (pointer-motion!)

func -> *domElement -> void   /   func -> string -> boolean   /   func -> number
```
Polled input, with no GL dependency (usable from any renderer): held keys,
pointer position and buttons, and pointer-lock for first-person cameras.

### `(gfx scene)`: Reactive GL Scenes

`sgl` is to the GL stack what `sx` is to the DOM. The template splits at
expansion time: geometry (from `(gfx mesh)`) builds and uploads once, and
each unquoted attribute becomes a signal-driven hole, so a frame is pure
arithmetic over current fields and only changed values move.

```scheme
(define angle (signal 0.0))
(define sc
  (sgl (camera (@ (fov 0.9) (position 0.0 3.5 9.0) (look-at 0.0 0.5 0.0)))
       (light  (@ (direction 0.5 0.8 0.4) (ambient 0.25)))
       (mesh   (@ (geometry (torus 1.6 0.55))
                  (position -1.8 0.6 0.0)
                  (rotation-y ,(signal-ref angle))
                  (color 0.95 0.45 0.35)))))
(fx-loop! (lambda (t dt)
            (cmd-clear! 0.05 0.06 0.10 1.0)
            (signal-set! angle t)
            (sgl-draw! sc)))
```

Tags: `camera` (`fov`, `near`, `far`, `position`, `look-at`), `light`
(`direction`, `ambient`), `mesh` (`geometry`, `position`, `rotation`,
`color`). Geometry specs mirror `(gfx mesh)` — `(plane w d)`, `(box …)`,
`(sphere r …)`, `(cylinder …)`, `(torus …)`, or an unquoted mesh injected
once. Everything renders through `mesh-lit-vs`/`-fs`.

### `(gfx gltf)`: Loading 3D Assets

GLB (binary glTF 2.0): the JSON chunk parses through `(web json)`, the
binary chunk sits in staging memory and accessors read f32/u16 straight
out of it — the wasm loads *are* the float decoder.

```
procedure: (gltf-fetch! url k)

func -> string -> procedure -> void
```
Fetch `url`, copy the bytes into staging memory, parse, and call `k` with
the `*gltf`. `gltf-parse base len` parses GLB bytes already in memory (so
parsing verifies headlessly). `gltf-load-textures! g k` decodes the
embedded images and hands each primitive its texture.

```
procedure: (gltf-draw! g prog vp [root])

func -> *gltf -> *fx-program -> vector -> void
```
Draw every primitive with `prog` and the view-projection `vp` — lit,
textured, or skinned depending on the program's stride. Loads: positions,
normals, both UV sets, node transforms, the full material model (below),
embedded images, cameras, skins, animations, and morph targets.

A material's texture slots come back as *references*, not image indices:
`gprim-base-tex`, `gprim-mr-tex`, `gprim-normal-tex`, `gprim-emissive-tex`
and `gprim-occlusion-tex` each answer a `gtexref` or `#f`, and a reference
names the glTF texture (`gtexref-texture`), the image it resolves to
(`gtexref-image`), its sampler (`gtexref-sampler`), which UV set it reads
(`gtexref-texcoord`) and its scalar (`gtexref-factor` — normal scale or
occlusion strength). The distinction that matters is texture versus
image: two textures may share one image and differ only in sampler.
`gltf-textures` and `gltf-samplers` hand back the file's own arrays, and
`gprim-base-color-factor` answers what the file wrote — `#f` when it
omitted `baseColorFactor` — where `gprim-color` always answers with a
colour. `gltf-cameras` and `gltf-node-camera` carry the cameras;
`gprim-morph-normals` and `gprim-morph-tangents` the morph deltas beyond
position. A second UV set rides at the *end* of the interleave, so an
asset that gains one moves nothing before it. Full detail, including the
byte layout, is in `docs/graphics.md`.

```
procedure: (gltf-animate! g i t)   (gltf-animate-blend! g a ta b tb k)

func -> *gltf -> int -> number -> void
```
Sample animation `i` at time `t` (looping), writing every channel's node
TRS. `gltf-animate-blend!` crossfades two clips by weight `k`.
`gltf-animation-names` lists them; `gltf-weights!` sets morph weights by
hand; `gltf-skin-vs` is the four-bone skinning vertex shader (pairs with
`mesh-tex-fs`). `anim-machine` / `anim-goto!` / `anim-update!` package
named states over clips with per-transition fades; interrupting a live
fade is continuous — the machine freezes the pose on screen and fades
from there, easing any node the incoming clip does not drive back to
bind over the same transition. What it still cannot do is layer: two
clips over one node blend by a single weight, never per path. Skinned
normals move by the blended matrix's cofactor with the determinant's
sign folded in, so a joint that scales unevenly or mirrors lights
correctly, and `gltf-skin-normals!` computes the same expression on the
CPU. See `examples/fx-fox.html`: a rigged Fox, Survey / Walk / Run
crossfading on keys 1–3.

Long form in `docs/graphics.md`.

### `(gfx glb)`: Writing GLB

The inverse of `(gfx gltf)`. A mesh built or edited in staging memory
leaves as a file any glTF tool reads: the writer takes the interleaved
vertex block and index block *already there* and wraps them in a
container, so nothing is repacked.

```
procedure: (glb-write! prims . options)

func -> list -> ... -> pair
```
Return `(base . length)` — the same pair `gltf-parse` takes, so a round
trip is one expression. A primitive is a plain list, not a record only
this library can build:

```
(layout vbase vcount ibase icount . options)
```
`layout` names the attributes present in the interleave's canonical
order, from the vocabulary `gprim-layout` reports: `position` `normal`
`uv` `tangent` `color` `joints` `weights` `uv1`. `glb-stride` and
`glb-offset` give a layout's byte stride and an attribute's place inside
it. A primitive's own options are `color`, `material`, `node`, `skin`,
`targets`, `weights`, `index-u32?`, `stride` and `joints-u16?`; `color`
asks for a material and `material` names one, so giving both is refused.

`glb-write!`'s own key/value tail carries everything that is not one
primitive's vertices: `nodes`, `mesh-node`, `skins` (or the older
singular `skin` — a one-element `skins` writes the same bytes), `anims`,
`images`, `samplers`, `textures`, `materials` and `cameras`. Each
material texture slot is `(texture texcoord factor)` or `#f`; a sampler
key given as `#f` is left out of the file rather than written as a
value; a material's base colour may be `#f`, which omits
`baseColorFactor` entirely.

Because the option shapes are the ones `(gfx gltf)` reads back, a parsed
asset feeds the writer directly — use `gprim-base-color-factor` rather
than `gprim-color` when re-exporting, since the latter substitutes a
neutral grey for a material that never wrote one. `docs/graphics.md`
carries the full re-export recipe.

Not written: images behind a `uri` (this writer embeds), names on
anything but nodes and animation clips, `alphaMode` / `doubleSided` and
the `KHR_materials_*` extensions, `extras` of any kind, and one mesh
instanced by several nodes — the reader flattens that sharing away, so
two nodes on one mesh come back as two meshes with the same contents.

Long form in `docs/graphics.md`.

### `(gfx collide)`: Collision and Raycasts

Overlap tests and raycasts over `(gfx mat)`'s `v3` — pure arithmetic,
verified headlessly, enough for the classic game loop.

```
procedure: (ray-aabb origin dir bmin bmax)   (ray-sphere …)   (ray-plane …)
           (ray-triangle …)   (ray-mesh origin dir mesh)

func -> vector -> vector -> … -> number
```
Cast a ray (direction must be a unit vector); return the hit distance in
world units, or `#f`. `ray-mesh` walks a `(gfx mesh)`'s triangles — with
`m4-unproject` it turns a click into a picked object.

```
procedure: (sphere-aabb-push c r bmin bmax)

func -> vector -> number -> vector -> vector -> vector
```
Return the vector that moves a sphere out of a box (or `#f` if not
overlapping) — the "slide along the wall" of a character controller.
`sphere-sphere?`, `aabb-aabb?`, `sphere-aabb?` are the boolean overlap
tests.

## Text Layout and Audio

Three libraries render text without the DOM's layout engine, and one
plays sound. `(web typeset)` is the shared foundation: layout as a pure
function, so heights are known before anything mounts and text can be set
in canvas/GL scenes.

### `(web typeset)`: DOM-Free Text Layout

Two phases, after [pretext](https://www.pretext.cool): `prepare` measures
each distinct code point once, `layout` is pure arithmetic from the cached
widths to line boxes — no DOM, no reflow.

```
procedure: (prepare text measure)

func -> string -> procedure -> *prepared
```
Measure `text`, calling `measure` (a one-code-point string → advance
width) once per distinct code point and caching. `(web typeset canvas)`'s
`canvas-measurer` supplies a `measure` backed by `measureText`; tests pass
arithmetic stand-ins.

```
procedure: (layout p max-width line-height)

func -> *prepared -> number -> number -> *layout
```
Lay `p` into line boxes within `max-width` (greedy first-fit): `\newline`
is a hard break, soft breaks fall at spaces, CJK breaks between ideographs
with kinsoku (closing punctuation never starts a line, opening brackets
never end one), over-wide words split by code point. `layout-height`,
`layout-line-count`, `layout-lines` read the result; each line gives
`line-text`, `line-width`, `line-y`. `string-fold-cp` folds a procedure
over the code points (byte offset and length), the hot-path primitive
sprite text uses.

### `(web glyphs)`: Glyphs That Dodge the Pointer

Explode an element's text into per-glyph absolute spans — the layout does
not move — and let each glyph dodge the pointer with spring-and-repulsion
physics. Two ways in, one group out. `glyphs!` takes plain text and
re-sets it through `(web typeset)`: pen positions kerning-normalized
against the whole-string width, letter-spacing honoured, `text-align`
center and right respected, and — for gradient text, whose clip would swallow the absolute spans — a solid colour sampled per glyph along the
run. `glyphs-mixed!` handles inline markup (`em`, `code`, `a`) instead:
re-setting would eat the tags, so each character's rectangle comes from a
DOM Range, glyph spans sit *inside* their own parents (an `em`'s glyphs
stay italic, a link's glyphs still click), and the original runs hide
behind `opacity:0`, which never disturbs layout.

```
procedure: (glyphs! el)   (glyphs-mixed! el)

func -> *domElement -> *group
```
Explode `el` and return a *group* record (one exploded element).
`glyphs!` for plain text, `glyphs-mixed!` for markup. `glyphs-group?`
tests the record; `glyphs-rebuild!` restores the original markup and
re-explodes at the current geometry (the resize handler calls it).

```scheme
(cons (if (plain? el) (glyphs! el) (glyphs-mixed! el)) groups)
```

```
procedure: (glyphs-dodge! groups)

func -> list -> void
```
The standalone driver for a list of groups: install the pointer, scroll,
and resize listeners and run an own `requestAnimationFrame` loop. Use this
when the page has no render loop of its own.

```
procedure: (glyphs-track! groups)   (glyphs-step! group)

func -> list -> void   /   func -> *group -> void
```
The split form, for driving from a loop you already run. `glyphs-track!`
installs only the listeners (pointer, scroll, resize); `glyphs-step!`
advances one group by a single spring step — call it per frame. This is
how the homepage hero drives its subtitle from its GL loop:

```scheme
(define sub-glyphs (glyphs! sub-el))
(glyphs-track! (list sub-glyphs))
;; ... then inside the GL frame:
(glyphs-step! sub-glyphs)
```

### `(gfx sprite)`: 2D Sprites and GL Text

A glyph atlas over `(gfx fx)` and `(web typeset)`. Each distinct code
point rasterizes once (hidden 2d canvas), uploads as one texture, and its
measurer doubles as typeset's `measure` — so layout and rendering agree
exactly.

```
procedure: (make-atlas font size [dim])

func -> string -> number -> int -> *atlas
```
An atlas for CSS `font`. `atlas-measurer` returns its `measure` for
`prepare`; `atlas-line-height` its line height.

```
procedure: (make-batch atlas [cap])   (batch-begin! b)   (batch-draw! b)

func -> *atlas -> int -> *batch
```
A quad batch. Per frame: `batch-begin!`, then `rect!` (a tinted solid),
`sprite!` (an atlas cell), `draw-text!` (a laid-out `*layout` at a pen
position), then `batch-draw!` — one buffer upload, one draw call.
Coordinates are pixels, top-left origin.

```
procedure: (load-image! url k)   (make-sheet img)   (sheet! sb …)   (sheet-draw! sb)

func -> string -> procedure -> void
```
Image sprite sheets ride a separate premultiplied path: `load-image!`
fetches, `make-sheet` uploads, and a sheet-batch (`make-sheet-batch`,
`sheet!`, `sheet-draw!`) draws source rectangles from it.

### `(web scroll)`: Virtual Scrolling

The use case `(web typeset)` was born for. Chat threads need an item's
height *before* it mounts; heights come from typeset's pure layout over
the same font, only the visible window is in the DOM, and one
`offsetHeight` read per newly mounted item corrects the estimates.

```
procedure: (make-vscroll parent width height font line-height)

func -> *domElement -> int -> int -> string -> number -> *vscroll
```
A scroller inside `parent`. `vscroll-append!` adds an item (sticking to
the bottom when the user is already there); `vscroll-render!` re-renders
the visible window. See `examples/chat.html`: an endless streaming feed.

### `(aud sfx)`: Game Sound

Procedural beeps (no asset files), decoded samples, looping music, over a
WebAudio bridge.

```
procedure: (audio-init!)

func -> void
```
Start the audio context — call from the first click or keydown, since
browsers refuse audio before a user gesture. `audio-time` reads the clock.

```
procedure: (beep! freq dur [vol wave])

func -> number -> number -> number -> string -> void
```
A procedural blip: frequency (Hz), duration (s), optional volume and
waveform (`"sine"`, `"square"`, …).

```
procedure: (load-sound! url k)   (play! buf [vol rate])   (loop-sound! buf [vol])

func -> string -> procedure -> void   /   func -> *jsObject -> number -> void
```
`load-sound!` fetches and decodes a sample, then calls `k` with the
buffer; `play!` fires it once (optional volume, playback rate);
`loop-sound!` starts a loop and returns a handle for `stop-sound!`.

## Networking

When both ends of the wire speak Scheme, the codec is `(web sexpr)`—byte-for-byte Igropyr's extended s-expression format, so binary and IEEE floats cross bit-exact. For a heterogeneous backend there is a safe JSON codec. Both run over `(web fetch)`, which turns HTTP into direct-style calls.

### `(web fetch)`: Direct-Style HTTP over JSPI

`(web fetch)` uses Wasm JSPI (JavaScript Promise Integration) to make HTTP read like a blocking call: `js-await` suspends the whole wasm stack on a promise and resumes with the value. No callbacks, no async coloring; the page stays responsive while suspended.

```scheme
(import (web fetch))

(let* ((page  (http-get "/manual.md"))
       (resp  (fetch "/api" '((method . "POST") (body . "hello"))))
       (body  (response-text resp)))
  (list (response-status resp) body))
```

A `*response` is the JS `Response` object; `opts` is an alist like
`((method . "POST") (body . "...") (headers . (("Content-Type" . "text/plain"))))`.

```
procedure: (fetch url [opts])

func -> string -> alist -> *response
```
Perform an HTTP request and return the response. Suspends the wasm stack
(JSPI) until the response head arrives.

```
procedure: (http-get url)

func -> string -> string
```
GET `url` and return the response body as a string.

```
procedure: (http-post url body [content-type])

func -> string -> string -> string -> string
```
POST `body` to `url` (default content type `text/plain`) and return the
response body as a string.

```
procedure: (response-status r)

func -> *response -> int
```
The HTTP status code, e.g. `200`.

```
procedure: (response-ok? r)

func -> *response -> boolean
```
Whether the status is in the 200–299 range.

```
procedure: (response-text r)

func -> *response -> string
```
Read the full response body as a string. Suspends until the body arrives.

```
procedure: (response-header r name)

func -> *response -> string -> string
```
Read one response header by name.

```
procedure: (fetch-direct?)

func -> boolean
```
Feature-detect JSPI: `#t` when direct-style suspension is available.

JSPI needs an engine that supports it (Chrome stable; Node with `--experimental-wasm-jspi`). Without it the underlying await import is the identity—feature-detect with `(fetch-direct?)` and fall back to the callback `rpc!` below. On the `--js` target the probe always answers `#f`, whatever the browser supports: that target has no stack to suspend, and its kernel hides the JSPI constructors from the program rather than let a probe say yes to a suspension that would not happen. One feature test therefore covers both targets. `js-await` is only legal on the main stack, not inside a `$jscb` callback re-entered from JS.

### `(web rpc)`: S-Expression RPC to a Scheme Backend

The peer is [Igropyr](https://github.com/guenchi/Igropyr), a Scheme application server. Both ends speak Scheme, so requests and replies are s-expressions—exact integers and ratios cross intact, binary and IEEE floats bit-exact, and there is no JSON in between. A `datum` below is any wire-safe s-expression: lists, symbols, strings, exact integers and ratios, booleans, vectors, bytevectors (`#vu8"…"`, base64) and flonums (`#f8"…"`, the 8 IEEE-754 bytes—`inf` and `nan` included). The codec is `(web sexpr)`, byte-for-byte Igropyr's extended mode.

```
procedure: (rpc url datum)

func -> string -> datum -> datum
```
Send `datum` to `url` and return the reply datum. Direct style — suspends
via JSPI until the reply arrives.

```
procedure: (rpc-get url)

func -> string -> datum
```
Fetch a resource served as `application/sexpr` and return it as a datum.

```
procedure: (rpc! url datum on-reply [on-error])

func -> string -> datum -> procedure -> procedure -> void
```
Callback-style RPC that works without JSPI: send `datum`, then call
`(on-reply reply)`, or `(on-error e)` on failure.

```
procedure: (rpc-serialize datum)

func -> datum -> string
```
Serialize a datum to the wire text via `(web sexpr)`—not the host
`write`—the depth-limited whitelist Igropyr's extended mode accepts.

```
procedure: (rpc-parse text)

func -> string -> datum
```
Parse wire text back to a datum via `(web sexpr)`—not the host `read`—same whitelist.

```scheme
(import (web rpc))

;; direct style (needs JSPI):
(rpc "/rpc" '(add 1 2 1/2))          ; => (ok 7/2)   -- the ratio survives
(rpc "/rpc" '(get-user 42))          ; => (ok (user (id . 42) (name . "ada")))

;; REST-style resource served as application/sexpr:
(rpc-get "/users/42")                ; => (user (id . 42) (name . "ada"))

;; callback style (works without JSPI):
(rpc! "/rpc" '(get-user 42)
  (lambda (reply) (render! reply))
  (lambda (e) (show-error! e)))       ; optional error thunk
```

The Igropyr side is symmetric—a tagged-dispatch endpoint whose handlers return the reply datum, wrapped `(ok ...)` / `(error ...)`:

```scheme
;; server (Igropyr): (igropyr express) + (igropyr sexpr)
(define users '((42 . "ada") (7 . "alan")))

(app-rpc app "/rpc"
  `((add      . ,(lambda (args) (apply + args)))
    (get-user . ,(lambda (args)
                   (let ((u (assv (car args) users)))
                     (if u
                         (list 'user (cons 'id (car u)) (cons 'name (cdr u)))
                         'not-found))))))
```

`rpc-serialize` / `rpc-parse` expose the wire codec directly—`(web sexpr)`, not the host `write` / `read`—over the depth-limited whitelist Igropyr's extended mode accepts: lists, symbols, strings, exact integers and ratios, booleans, vectors, bytevectors and flonums.

For pushed streams there are two thin companions, matching Igropyr's `ws-send-sexpr!` / `sse-send-sexpr!` on the server—each message is one datum. A `*ws` is a WebSocket handle, a `*sse` an EventSource handle.

```
procedure: (ws-connect! url on-datum [...])

func -> string -> procedure -> *ws
```
Open a WebSocket to `url`; `(on-datum d)` fires once per message with the
decoded datum. Returns the socket handle.

```
procedure: (ws-send! w datum)

func -> *ws -> datum -> void
```
Send one datum over socket `w`.

```
procedure: (ws-close! w)

func -> *ws -> void
```
Close the socket.

```
procedure: (ws-open? w)

func -> *ws -> boolean
```
Whether the socket is open.

```
procedure: (sse-connect! url on-datum [...])

func -> string -> procedure -> *sse
```
Open a Server-Sent-Events stream; `(on-datum d)` fires once per event.
Returns the stream handle.

```
procedure: (sse-close! es)

func -> *sse -> void
```
Close the SSE stream.

```scheme
(import (web ws) (web sse))

(define w (ws-connect! "wss://host/chat/lobby"
            (lambda (datum) (render! datum))))   ; one datum per message
(ws-send! w '(say "hello everyone"))

(sse-connect! "/progress"
  (lambda (datum)                                ; (progress (percent . 42))
    (update-bar! (cdr (assq 'percent (cdr datum))))))
```

### `(web json)`: Safe JSON for Heterogeneous Backends

When the peer is not Scheme, `(web json)` is a safe recursive-descent codec (not the reader—no `#`-syntax, no eval), the same one Igropyr uses on the server, ported from its `json.sc`.

```
procedure: (string->json s)

func -> string -> any
```
Parse a JSON string: object → alist (string keys), array → vector,
string → string, number → number, `true`/`false` → `#t`/`#f`, `null` → `'null`.

```scheme
(string->json "{\"user\":{\"id\":42,\"tags\":[\"a\",\"b\"]}}")
=> (("user" ("id" . 42) ("tags" . #("a" "b"))))
```

```
procedure: (json->string x)

func -> any -> string
```
Serialize a Scheme value (same data model) to a JSON string.

```scheme
(json->string '(("ok" . #t) ("n" . 42)))
=> "{\"ok\":true,\"n\":42}"
```

```
procedure: (json-ref x key ...)

func -> any -> any -> ... -> any
```
Walk a path by string/symbol key (objects) or integer index (arrays),
returning `#f` when any step is absent.

```scheme
(json-ref (string->json "{\"user\":{\"id\":42}}") "user" "id")
=> 42
```

Data model: object → alist with string keys, array → vector, string → string, number → number, `true`/`false` → `#t`/`#f`, `null` → `'null`. `\uXXXX` and surrogate pairs decode to UTF-8 bytes (Goeteia strings are UTF-8 byte strings); huge integers stay exact bignums. `(json-ref x k ...)` walks a path by string/symbol key (objects) or integer index (arrays), returning `#f` when absent. Combine with `(web fetch)`:

```scheme
(let ((data (string->json (http-get "/api/user/42"))))
  (json-ref data "name"))
```

## Running in the Browser

For a page you generate, this section is mostly *background*: the mount points of [Single-File Pages](#single-file-pages) compile the section into the page with the loader glue inlined beside it, `define-wasm-js` emits the JS fallback from the same source, and a capability gate reaches the loader through the `globalThis.__goeteia_load` handle the glue publishes. Nothing below is written by hand on that path.

You reach for the API directly in one situation: **embedding a compiled module into a page you do not generate**—an existing site, another framework's tree (see `examples/react-embed.html`). Deploy `rt/web.mjs` and `rt/jsbridge.mjs` next to the page; the loader instantiates the module and runs it on the main thread with full DOM access:

### A Hand-Written Shell

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>My App</title>
</head>
<body>
  <div id="app"></div>
  <script type="module">
    import { loadGoeteia } from './rt/web.mjs';
    loadGoeteia('app.wasm');
  </script>
</body>
</html>
```

The Scheme program can then manipulate the DOM via `(web dom)` and `(web sx)`.

### Engines without Wasm GC

Wasm GC is not everywhere yet—older Safari, older Chrome, embedded WebViews. On the generated-page path `(define-wasm-js (app "app.wasm" "app.js") ...)` produces the pair and the deciding loader in one build. On a hand-written shell you compile the second artifact yourself with `--js` (see [Compiling to JavaScript](#compiling-to-javascript)) and call the same decision point:

```javascript
import { loadGoeteiaAuto } from './rt/web.mjs';

loadGoeteiaAuto('app.wasm', 'app.fallback.js');
```

`hasWasmGC()` decides by validating a minimal module carrying one struct type—engines from before the proposal reject the typecode. When it passes, `loadGoeteiaAuto` is just `loadGoeteia`. When it fails, it runs the fallback, which is either of two shapes:

- **a `.js` or `.mjs` URL**, `import()`ed dynamically at that moment;
- **a CSS selector** for an inert `<script type="goeteia/js">` tag holding the module text inline—the default, `script[type="goeteia/js"]`. The browser ignores a script of unknown type, so the text just sits in the document until the loader takes its `textContent`, strips the `export` keywords, and calls `main`.

Append `?goeteia=js` to the page URL to force the fallback on an engine that does have Wasm GC—that is how you test it.

Which shape to use is a question of *when* the fallback is fetched, not of size: a server gzips inline HTML the same as a served file. A separate file is lazy—visitors with Wasm GC never download it, and it caches under its own URL, independent of the page. Inline costs every visitor a download that few of them execute, and buys self-containment: one file to copy, with nothing fetched alongside it. Prefer the separate file for a deployed site; inline when the page itself is the unit you distribute.

Either way the glue also publishes the loader as `globalThis.__goeteia_load`, which is how a `define-js` gating section (capability degradation—see [Fallback Is Two Questions](#fallback-is-two-questions)) starts a heavy module without importing anything.

### Single-File Pages

Inlining the fallback makes a Goeteia page one HTML file, the way an inline `<style>` makes a stylesheet part of the document. You do not assemble that file with a separate tool: `conjure` is a *mount point*, a language-level form that puts browser code inside the program that prints the page.

```
syntax: (conjure mode body ...)

mode -> body ... -> string
```
Compile `body ...` as an **independent program**—its own prelude, its own `import`s resolved in a fresh scope of their own—and yield the whole form as **one HTML string constant** in the host program. `mode` is `js`, `wasm`, or `auto`, or the list form `(mode (wasm-url "url"))`:

- **`js`** — the `--js` module inline in a `<script type="module">`, invoked directly. Nothing to load, nothing to detect.
- **`wasm`** — the wasm module, loaded through `loadGoeteia`. By default it rides along as a `data:application/wasm;base64,` URI; `(wasm (wasm-url "app.wasm"))` points at a file instead.
- **`auto`** — both artifacts: the `--js` module in an inert `<script type="goeteia/js">` tag, the wasm handed to `loadGoeteiaAuto`, which picks by engine support at load time.

A `wasm` or `auto` section **always inlines the runtime glue** (the JS bridge and the loader, with the module plumbing stripped)—the compiler drivers supply it, so a generated page depends on nothing beside itself and there is no `rt/web.mjs` to serve. Each `auto` section's fallback tag gets a unique, deterministic id (`goeteia-conjure-0`, `goeteia-conjure-1`, …) so several sections coexist on one page; the glue repeats verbatim across them, which is what gzip is good at.

The host is a site generator, so the page around the mount point is ordinary `(web html)` SXML and the section string splices in through `raw`:

```scheme
(import (web html))

(display
 (html->document
  `(html
    (head (meta (@ (charset "utf-8"))) (title "Counter"))
    (body
     (div (@ (id "app")))
     ,(raw
       (conjure auto
         (import (web reactive) (web sx) (web dom))
         (define n (signal 0))
         (sx-mount (get-element-by-id "app")
           (sx (div
                 (div (@ (id "count")) ,(signal-ref n))
                 (button (@ (on-click ,(lambda _ (signal-update! n (lambda (v) (+ v 1))))))
                   "+"))))))))))
```

Compile *that* program and run it: what it prints is the finished page, both artifacts and the loader inside it.

Two rules follow from the staging. A mount point must appear **literally in the source**—it is resolved before macro expansion, so a user macro cannot produce one. And each block is its own import scope: the host's `(import (web html))` is not in scope inside the body, and the body's `(import (web sx))` is not in scope outside it. Nested mount points work, each with its own scope again.

#### The `define-` family

The three modes also come as definition forms, which dispatch on the **shape of the head** the way `define` itself does—a bare name or a pair:

```
syntax: (define-js name body ...)
syntax: (define-js (name "app.js") body ...)
syntax: (define-wasm name body ...)
syntax: (define-wasm (name "app.wasm") body ...)
syntax: (define-wasm-js name body ...)
syntax: (define-wasm-js (name "app.wasm") body ...)
syntax: (define-wasm-js (name "app.wasm" "app.js") body ...)
```
Bind `name` to the section string for `body ...`. A bare `name` keeps the artifact inside the page—the wasm module as a `data:` URI, the JS module as an inline script. A file form makes the section reference the URL **and writes the file**: the definition expands to the section plus a `with-output-to-file`, so the generator drops the artifact next to its page output when it runs. Pages sharing one module this way let the browser cache it across them. In `define-wasm-js` the name's order is the load preference: wasm first, the JS module as the fallback. Its three-element form writes *both* artifacts as files and the section carries only the loader call; the fallback is then **lazy**—an engine with WasmGC never downloads it, and the file caches independently of the page. (That fallback module is imported by the loader, which calls its `main` itself; `define-js`'s own URL form writes a *self-running* module instead, since a `<script src>` has no caller.)

```scheme
(define-wasm-js (app "app.wasm")
  (import (web dom))
  (console-log "hello"))

(display (html->document `(html (body ,(raw app)))))
```

Pasting compiler output into HTML is safe by construction: the JS emitter escapes `<` inside string literals, so no emitted literal can spell `</script` and close the tag early. The mount point checks its own output for a script terminator anyway and raises rather than emit a page that could break out of the tag.

#### Fallback Is Two Questions

The word *fallback* hides two different questions, and the mount points split them deliberately.

**Engine fallback** asks: *what if the engine cannot run WasmGC?* The answer is mechanical—run the same program compiled to JavaScript—so `define-wasm-js` automates it entirely. The twin is generated from the same source on every build; nobody maintains it, so it cannot drift, and a differential test can hold the two backends to identical behaviour.

**Capability degradation** asks: *what if the feature itself should not run here?* No WebGL2, a canvas with no layout box yet, a multi-megabyte module that should not even be fetched on this device. That answer is application logic—reveal the canvas *before* measuring it, probe, and only then load; undo the reveal if anything on that road fails—so no compiler can generate it. It is not macro clauses either (a `require`/`on-fail` vocabulary could never express the *ordering*). It is simply **another mount point**: a `define-js` section that orchestrates probes, loads and rollback in Scheme.

The one piece of plumbing that makes the composition work: every wasm/auto section's inlined glue publishes its loader as `globalThis.__goeteia_load`. A gating section reaches it through the FFI—

```scheme
(define-js gate
  (import (web js) (web dom))
  (when (js-truthy? (js-method canvas "getContext" "webgl2"))
    (js-method (js-call (js-get (js-global) "__goeteia_load")
                        (js-undefined) "/heavy.wasm")
               "catch"
               (lambda (e) (roll-back!) (js-undefined)))))
```

—and document order guarantees the handle exists: module scripts run in sequence, and any wasm/auto mount earlier in the page has already set it synchronously. A page whose only mounts are `define-js` has no glue and no handle, but such a page has no wasm to load either.

### Example

See `examples/counter.html` and `examples/counter.ss`—a complete counter app, page shell and program kept apart—and `examples/counter-page.ss`, the same app written as a site generator with an `auto` mount point. Running it prints `examples/counter-embedded.html`: the same page as one self-contained file, wasm module, `--js` fallback and loader all inside it, fetching nothing. That output is generated, not maintained—`examples/mk-counter-embedded.sh` is the whole recipe. Also see `examples/react-embed.html` for embedding Goeteia widgets into a React app.

## Testing

Run the test suite:

```bash
./run-tests.sh
```

### Test Protocol

Each test file declares its expected output in the first line:

```scheme
;; expect: 42
(+ 21 21)
```

The test runner:
1. Compiles the test with both the Chez-hosted and self-hosted compilers (if `goeteia.wasm` exists)
2. Runs each, capturing output
3. Compiles it a third time with `--js` and runs that under `rt/runjs.mjs`, checking that the two hosts emitted byte-identical JS text
4. Verifies every result matches the expectation

Alongside the three columns it runs a set of `.mjs` cases that pin the JS target's *failure* behavior to wasm's—division by zero, collection and byte-memory bounds, dynamic arity, operand types, float conversion, memory growth, the trampoline, the JSPI probes—since an expectation line can only check the runs that succeed.

### Input Files

For tests that read input, create a `.input` file alongside the test:

```
test/readnums.ss       <- test file
test/readnums.input    <- input file (byte stream)
```

`run-tests.sh` passes the input file as stdin to `rt/run.mjs`.

### Headless DOM Testing

The `(web sx)` and `(web reactive)` libraries run against a mock DOM defined in JavaScript:

```scheme
;; Set up a mock DOM
(js-eval "globalThis.document = {
  createElement: ...
  ...
}")

;; Now run Goeteia DOM code against the mock
(define el (create-element "div"))
(append-child! (body) el)
```

See `test/sx.ss` and `test/todomvc.ss` for full examples. The mock DOM prints errors if you call methods that aren't implemented, making it easy to catch missing APIs during development.

## Porting from JavaScript/TypeScript

The project ships a subagent defined in `.claude/agents/web-porter.md`
that ports a single UI file from JavaScript/TypeScript to Goeteia
Scheme. It:

1. **Translates** a JS/TS file to idiomatic Goeteia (React hooks →
   signals, JSX → `sx` templates, DOM APIs → `(web dom)`)
2. **Verifies** behavioral equivalence by differential testing: it
   drives the original and the port through the same inputs/events and
   compares outputs, fixing the port until they match
3. **Reports** anything it cannot make equivalent as marked TODOs

Scope is the UI subset plus well-behaved logic; it flags pathological
JS-semantics corners (deep `this`/prototype dispatch, `==` coercion)
rather than emulating them. It is a same-result porter, not a general
JS-in-Scheme runtime.

It runs like any Claude Code subagent — inside a session, by asking
Claude to use the `web-porter` agent on a file — not as a standalone
shell command.

## Dispatch and Rules

Rules that grow a case at a time — "fire against a mage", "fire against
anyone" — need an answer to which one runs, and the two usual answers
(first registered, last registered) both make the behaviour depend on
where a `define` sits in a file. `(lng pred)` and `(lng generic)` make
the relation between rules **declared** and a conflict with no declared
answer an **error the program reports**; `(lng machine)` does the same
for state machines, which it keeps as data rather than as code, and
`(lng effect)` for what several sources do to one quantity. No classes, no inheritance, no
method combination. Not for per-frame work: dispatch here is for event
and turn granularity. Long form in `docs/lng.md`.

### `(lng pred)`: Classifiers and Their Relations

```
procedure: (define-classifier name proc tags)

func -> symbol -> procedure -> list -> *classifier
```
A classifier maps a value to a symbol out of a **declared finite** set.
`classify c x` answers the tag and refuses one outside the domain.
`declare-subtag! c sub super` records that `sub` is a kind of `super`,
refusing a declaration that would close a cycle; the relation is kept
as a reflexive, transitive closure, so `subtag? c 'paladin 'warrior`
and `descendants c 'warrior` (which includes `warrior` itself) read it
back. A diamond — paladin under both warrior and healer — is allowed.

Finiteness is the point: because the tag set is declared, every tuple
two handler signatures could both match can be enumerated, which is
what turns an ambiguity into something the program can state when the
rules are installed. `declare-subset!` and `subset?` are the same
relation over ordinary predicates.

### `(lng generic)`: Dispatch on Several Arguments

```
procedure: (make-generic name arity (classifiers c ...) [default])

func -> symbol -> int -> list -> *generic
```
Answers an ordinary procedure of that arity, so a generic goes wherever
a procedure is wanted. Arity is 1 to 4 — dispatch is written out per
arity because this runtime has no `apply` — and a fifth is refused at
construction. A **signature** has one entry per argument, a tag or `_`
for any; the applicable handler that is most specific *at every
position* wins, and one that is more specific in one argument and less
in another conflicts rather than winning.

```
procedure: (add-handlers! g pairs)

func -> *generic -> list -> boolean
```
`pairs` is a list of `(signature . procedure)`.
Every change is a **transaction**: `add-handler!`, `add-handlers!`,
`remove-handler!` and a `declare-subtag!` touching a classifier the
generic uses each validate the whole proposed configuration before
committing it, and leave the previous one untouched when they refuse.
So `(fire _)` and `(_ mage)` are refused together — `(fire mage)`
matches both and neither is more specific, and the irritants name that
tuple — while the same two committed *with* `(fire mage)` are accepted.
Signatures that resolve an overlap must be committed with it; splitting
them across two commits is refused at the first. Removing the handler
that resolved an overlap is refused and removes nothing.

`generic-check!` revalidates on demand, `generic-handlers` lists
handlers in registration order, and `generic-default!` installs a
default after construction. At the call, nothing applicable runs the
default or — with none — refuses under the generic's own name with the
arguments as irritants; a tag outside a classifier's domain refuses
**even when a default exists**, because the domain is what every
conflict check was computed over.

```
procedure: (dispatch-trace g args)

func -> *generic -> list -> list
```
What a call would do, without doing it: `(tags candidates winner)` —
the tuple, every candidate signature in registration order, and the
winner's signature or `#f`. A diagnostic, so it never runs a handler.

Predicate mode (`'predicates` in place of the classifier list) takes
open-ended predicates and can only report ambiguity at the call.

Long form in `docs/lng.md`.

### `(lng machine)`: State Machines as Data

A machine's states, initial state and transitions are lists of
symbols; guards and actions are **names**. The guard names are bound
to procedures when the machine is made; the action names are not —
they are handed back to the caller and never called here. Nothing in the spec is a procedure, so it can be
written to a file, read back and drawn.

```scheme
(define door-spec
  '((states (closed open locked))
    (initial closed)
    (transitions
     ((closed push open) (open push closed)
      (closed lock locked has-key)
      (closed lock closed no-key ring-alarm)
      (locked unlock closed has-key)))))
```

A transition is `(from event to)` with an optional guard name and then
an optional action name. Guard names need bindings — a guard is a
question the library asks. Action names do not: an action is handed
back to the caller by name and never called here. Several transitions may share a
`(state, event)` key only when every one of them is guarded; all those
guards run on each step and exactly one may hold. Two holding at once
is an error naming both — writing order carries no meaning, and the
two other places it could have (a clause written twice, a name bound
twice) are refused rather than resolved by position. That is the one
modelling error reported at the step rather than at construction,
because guard truth is a run-time fact.

Order independence assumes guards are **pure**: one that writes the
context can make its neighbours' answers depend on which ran first,
and the library cannot see that.

```
procedure: (make-machine spec bindings)
procedure: (make-machine spec bindings ctx)
procedure: (make-machine spec bindings ctx opts)

func -> list -> list -> any -> list -> *machine
```
Build a machine. `bindings` is an alist from guard name to a procedure
of one argument, the context. `ctx` is the initial context and must be
a datum (default `()`). `opts` understands `(strict #f)`, which allows
states unreachable from the initial one — useful for a fragment
assembled at run time. An option is exactly `(name value)`: a name
this library does not know, a missing value, an extra element and a
`strict` that is not `#t` or `#f` are each refused by name. Refused by name: an unknown state in a
transition, a state that is not a symbol, an initial state that is not
declared, a clause or an option given twice, an option with no value,
two unguarded transitions on one key, a bindings entry that is not
`(name . procedure)` or binds a name twice, a guard name with no
binding, an option name this library does not know, anything that is
not a datum in the spec, the options or the context — a procedure or
a cycle included — and unreachable states unless `strict` is off. A
spec may carry clauses the library does not know, since it is the
caller's data and round trips; an option may not, since an
instruction the library cannot read is a misspelling rather than a
weaker request. A cyclic value is named in the error but never
carried in it: printing it would not terminate either.
Reachability is structural — an edge counts even if its guard could
never hold.

```
procedure: (machine? x)

func -> any -> boolean
```
Whether `x` is a machine.

```
procedure: (machine-step m event)
procedure: (machine-step m event ctx)

func -> *machine -> symbol -> any -> (values *machine list)
```
Two values: the machine after the event, and the **names** of the
actions that transition asks for. It performs none of them. A `ctx`
given here replaces the machine's for this step and is retained in the
machine that comes back. An event with no transition — and one whose
guards all fail — leaves the machine as it is and answers no actions,
unless the spec carries `(on-unknown error)`, which makes it an error
by name.

```
procedure: (machine-state m)
procedure: (machine-ctx m)
procedure: (machine-spec m)

func -> *machine -> any
```
The current state, the retained context, and the spec as written.

```
procedure: (machine-events m)

func -> *machine -> list
```
The events available from the current state, structurally: no guard is
evaluated. This is the question a UI asks when it decides which
buttons to disable.

```
procedure: (machine-transitions m)

func -> *machine -> list
```
Every transition, for diagnostics and diagrams.

```
procedure: (machine->datum m)

func -> *machine -> list
```

```
procedure: (datum->machine d bindings)

func -> list -> list -> *machine
```
The round trip. The datum carries the spec, the current state, the
context and the strictness — everything but the procedures, which are
named in the spec and supplied again to `datum->machine`. A guard
name without a binding is refused there by name, so a save file
cannot quietly load as a machine whose guards do nothing.

### `(lng effect)`: What Several Sources Do to One Quantity

An effect is a record — kind, source, priority, phase, payload — and a
policy per kind says how the payloads combine. `resolve` folds them
and answers both the result and where each part came from. Every
ordering the answer depends on is in the data: the phase list, the
priority number, and the order the effects were collected, which a
stable sort preserves. Nothing depends on registration order or on
which module loaded first.

Policies are **names**, not procedures — `sum`, `max`, `min`, `last`,
`all` are built in and any other name is bound by the caller — so the
whole input to `resolve` is a datum that can be written out and
replayed.

```
procedure: (make-effect kind source priority phase payload)

func -> symbol -> symbol -> number -> symbol -> any -> *effect
```
Build an effect. Kind, source and phase are symbols and priority is a
number; the payload is anything at all, since mid-run it is often a
live object. Refused by name if any of the first four is the wrong
sort of thing.

```
procedure: (effect? x)
procedure: (effect-kind e)
procedure: (effect-source e)
procedure: (effect-priority e)
procedure: (effect-phase e)
procedure: (effect-payload e)

func -> any -> any
```
The predicate and the five accessors.

```
procedure: (resolve effects phases policies)
procedure: (resolve effects phases policies bindings)

func -> list -> list -> list -> list -> (values list list)
```
Two values: `((kind . value) …)` and the provenance,
`((kind (source . payload) …) …)`, both in the order the kinds first
contribute. `phases` is the phase order; `policies` is
`((kind . policy-name) …)`; `bindings` is `((name . procedure) …)` for
any policy name that is not built in, each procedure taking the
payload list in fold order. Refused by name: a phase listed twice, a
kind with two policies, a policy name neither built in nor bound, a
built-in name rebound, a name bound twice or bound to a non-procedure,
an effect in a phase not listed, a kind with no policy, a cyclic list.

```
procedure: (collect-effects producers arg ...)

func -> list -> any -> list
```
Call each producer with the same arguments and append what they
returned, in the order the producers are listed. This is the only
combining the library does: a producer contributes because it is named
here. A producer that is not a procedure, or that returns anything but
a list of effects, is refused by name.

```
procedure: (effect->datum e)
procedure: (datum->effect d)

func -> any -> any
```
The round trip, so a run can be replayed. `effect->datum` refuses a
payload that is not a datum — a procedure, a cycle — which is where
that has to be checked; `datum->effect` refuses anything that is not
an effect datum.

## Game Scaffolding

The `(gam …)` libraries hold the bookkeeping a game repeats and none of
the numbers a game chooses. Each of the five is independent — they
import nothing but `(rnrs)`, and none of them knows the others exist, so
a project takes the two it wants and leaves the rest.

What they deliberately leave out is as much of the design as what they
keep. There is no experience curve, no level reward, no damage figure,
no range, and no fixed set of pools: every one of those is a decision
about a particular game, and a library that held them could only be used
by the game it was cut from. What is here instead is the part that is
the same everywhere and easy to get subtly wrong — spending that must
not half-succeed, an objective that must not count twice, a listing
whose order must not depend on what the player happened to do.

Two rules run through all five. **Names, not indices**: a pool, an item,
an objective and an effect are all named, because an index is an
unwritten agreement between library and caller that fails silently when
it is off by one. **Every listing is in a maintained order**, never one
computed from a hash table, because byte-for-byte agreement between the
two compiler targets is a tested property of this system and an order
that came out of a table would break it invisibly.

Keys and names must be values `eq?` is dependable on — symbols,
characters, booleans, fixnums. Anything else is refused by name rather
than accepted and then silently never matched; on large integers this is
not hypothetical, since `eq?` on two separately computed equal ones
answers differently on the two targets.

### `(gam stats)`: Named Pools and Experience

```
procedure: (make-stats pools)
procedure: (make-stats pools curve)
procedure: (make-stats pools curve on-level)

func -> list -> procedure -> procedure -> *stats
```
`pools` is `((name max regen-per-second) …)`, in the order you want them
back. `curve` maps a level to the experience needed to leave it;
**without a curve nothing ever levels up** and `stats-gain-xp!` only
accumulates. `on-level` is called as `(on-level stats new-level)` once
per level gained — whatever a level grants is written there, not here. A
repeated pool name is an error: the second one would be unreachable.

```
procedure: (stats? s)

func -> any -> boolean
```
Whether a value came from `make-stats`. Every other procedure here
refuses anything else by name rather than reading a stranger's slots.

```
procedure: (stat s name)          (stat-max s name)

func -> *stats -> symbol -> number
```

```
procedure: (stat-set! s name v)   (stat-add! s name d)

func -> *stats -> symbol -> number -> number
```
Read and write one pool. Writes clamp into `[0, max]`. **A name that is
not a pool raises; it does not answer `0` or `#f`** — a typo that reads
as an empty pool is a bug found in a playtest instead of at the call.

```
procedure: (stats-spend! s name amount)

func -> *stats -> symbol -> number -> boolean
```
Spend if the pool holds enough: `#t` and the amount is gone, or `#f`
and **nothing at all is deducted**. There is no partial spend — the
caller would go ahead having paid less than it asked to.

```
procedure: (stats-damage! s name amount)
procedure: (stats-heal! s name amount)

func -> *stats -> symbol -> number -> number
```
Both answer **what actually happened**, which is not the amount asked
for once the pool hits its floor or its maximum. That is the number to
report or to feed a counter with. A negative amount is an error in
either direction.

```
procedure: (stats-regenerate! s dt)   (stats-refill! s)

func -> *stats -> number -> void
```
Each pool moves by its own rate for `dt` seconds and clamps at its
maximum; a rate of `0` is a pool that only ever refills explicitly. A
negative `dt` is refused rather than quietly draining everything.

```
procedure: (stats-level s)   (stats-xp s)
procedure: (stats-gain-xp! s amount)

func -> *stats -> number -> int
```
Levels start at `1`. `stats-gain-xp!` answers **how many levels were
gained**, `0` when there is no curve. A curve that answers a cost of
zero or less is refused: believing it would raise a level for free and
never terminate, and a hang is far harder to diagnose than a named
error.

There is deliberately **no invulnerability timer here**. A temporary
state belongs in `(gam effects)`; one living in a pool would make
`stats-damage!` depend on a clock that appears nowhere in its arguments.
Decide immunity before you call, where the decision is visible.

Long form in `docs/game.md`.

### `(gam inventory)`: Counted Things in a Stable Order

```
procedure: (make-inventory)
procedure: (inventory-count bag key)
procedure: (inventory-add! bag key n)

func -> *inventory -> symbol -> int -> int
```
`inventory-add!` answers the count after adding. `n` must be a positive
exact integer — **zero is refused too**, since adding nothing means the
arithmetic that produced the count went wrong somewhere the caller can
still find.

```
procedure: (inventory-take! bag key n)

func -> *inventory -> symbol -> int -> boolean
```
All or nothing: `#t` and the items are gone, or `#f` and **not one is
removed**.

```
procedure: (inventory-items bag)

func -> *inventory -> alist
```
`((key . n) …)` in the order the keys were **first added**, always, on
both targets. The pairs are copies, so writing to them cannot move a
count past the checks. A key taken down to zero **keeps its row and its
place**: dropping it would send it to the end when it is added again,
and the listing would become a record of what the player did rather than
of what the bag holds.

Long form in `docs/game.md`.

### `(gam quest)`: Objectives That Count Once

```
procedure: (make-quest required)
procedure: (quest-count q)   (quest-complete? q)

func -> list -> *quest
```
`required` is the objectives, and a repeated one is an error — it would
make the denominator of `quest-complete?` larger than the numerator can
ever reach, which shows up only when a player gets all the way to the
end.

```
procedure: (quest-record! q key)

func -> *quest -> symbol -> boolean
```
Answers whether **this call** advanced the quest, so a sound or a line
plays exactly once. Recording an objective already recorded answers `#f`
and changes nothing: the event behind it is usually a trigger volume or
a bus, and neither promises to fire once. An objective this quest does
not require is `#f`, not an error — a shared bus carries everything to
everyone.

```
procedure: (quest-keys q)
procedure: (quest-restore! q keys)

func -> *quest -> list -> void
```
`quest-keys` answers the objectives met **in the order the quest
declared them**, never in the order the events arrived. Two players with
the same objectives met get the same answer, and a save file reloads to
the same answer. `quest-restore!` clears and replays through
`quest-record!`, so a hand-edited save gets exactly the checks a live
event gets.

Long form in `docs/game.md`.

### `(gam effects)`: States That End by Themselves

```
procedure: (make-effects)
procedure: (effect-set! fx name duration)
procedure: (effect-ref fx name)     (effect-active? fx name)

func -> *effects -> symbol -> number -> void
```
`effect-ref` answers the time left, or `#f` when the name is not
running — not `0`, which is a duration this library never stores.
**Setting a name that is already running replaces its duration**: it
does not take the larger of the two and it does not add them. Refreshing,
extending and letting the longer win are three different rules a game
can want and a player can feel; read `effect-ref` first and set the
maximum yourself if that is the one you want. A duration of zero is
refused.

```
procedure: (effects-tick! fx dt)
procedure: (effects-clear! fx)
procedure: (effects-names fx)

func -> *effects -> number -> void
```
Every effect loses `dt`, **and then** what has run out is removed — in
that order, so an effect with exactly `dt` left is gone after the tick
that consumed it rather than one tick later. Reaching zero is running
out. A negative `dt` is refused.

`effects-names` is in the order the names were set. A name refreshed
while it is still running keeps its place; a name that ran out and is
set again is a new effect and goes last. That is deliberately unlike
`inventory-items`, and for a reason: a count of zero means the thing is
still there, while a duration of zero means the state is gone.

Long form in `docs/game.md`.

### `(gam abilities)`: Cooldowns, and Nothing Else

```
procedure: (make-ability id cost cooldown)
procedure: (ability? a)   (ability-id a)
procedure: (ability-cost a)   (ability-cooldown a)

func -> any -> number -> number -> *ability
```
`ability-cooldown` is the **length** of the cooldown, fixed when the
ability is made; `ability-remaining` below is **how much is left**. One
is configuration and the other is state, and code that confuses them
reads as though it works. A cooldown of zero is refused — an ability
that is instantly ready again has no cooldown, and saying so with this
type only hides that every call around it does nothing. A cost of zero
is fine.

```
procedure: (ability-remaining a)   (ability-ready? a)
procedure: (ability-tick! a dt)
procedure: (ability-use! a)

func -> *ability -> number -> boolean
```
`ability-use!` answers whether the use happened: ready, and the cooldown
is set to its full length; not ready, and **nothing changes** — a
refused use does not restart a cooldown that is still running.
`ability-tick!` counts down and clamps at zero.

**`ability-use!` does not spend the cost.** It does not touch a pool and
does not know pools exist; `cost` is a number the ability carries, for
you to subtract wherever your resources live:

```scheme
(when (and (ability-ready? fireball)
           (stats-spend! player 'mana (ability-cost fireball)))
  (ability-use! fireball)
  ...)
```
Tying the two together would mean an ability could only ever be paid for
out of one kind of thing, in one currency; an ability that costs two
resources, or none, would stop fitting. Damage and range are absent for
the same reason — an ability that heals or opens a door has neither.

Long form in `docs/game.md`.

### `(gam save)`: A Saved Game, and Whether Saving Works at All

```
procedure: (make-save-store key version validator)

func -> string -> int -> procedure -> *save-store
```
A store over one `localStorage` key. `version` is an exact integer,
compared for equality when a save is read back — an inexact one would
make "the same version" a question about rounding. `validator` is your
own predicate on the value; it never sees the version, which travels as
a wrapper around your datum rather than as a field written into it.

```
procedure: (save-available? store)

func -> *save-store -> boolean
```
Whether this machine can actually save. It writes and removes a probe
key, because a store that is *present* is not the same as one that
accepts a write — a private window keeps `localStorage` in place and
refuses `setItem`. **This never raises**: it is the question you ask in
order to avoid the raise, once at startup.

```
procedure: (save-load store)

func -> *save-store -> any
```
The saved value, or `#f`. Four different disappointments answer `#f` —
nothing stored, a version this build cannot read, contents the validator
rejected, and text no longer readable at all — because a caller has
exactly one thing to do about any of them: start a new game.

A store that cannot be used **raises** instead, naming the procedure.
That is a fact about the machine, not about the save, and answering `#f`
for it produces the worst failure a save system has: every launch starts
a new game, every save appears to work, and nothing is ever written.

```
procedure: (save-write! store value)

func -> *save-store -> any -> boolean
```
Answers `#t`. Raises if the store cannot be written, and — deliberately
not symmetric with `save-load` — **also raises if your own validator
refuses the value**. On the way in, a rejected value is your bug: you
assembled the thing you are trying to store, and answering `#f` would
let a game write nothing for an hour and find out at the next launch. On
the way out, a rejected value is a fact about a file that an older build
or a text editor may have produced, which is not the caller's mistake.

The stored text is an s-expression through `(web sexpr)`, so exact and
inexact numbers keep their kind and a flonum survives bit-exactly,
signed zero included — a save file is exactly the kind of data a decimal
round trip quietly damages.

Long form in `docs/game.md`.

## Simulation

Six libraries for the part of a program that is not drawing: who exists,
what runs each tick, who hears what, how time is divided, where the
randomness comes from, and which cell a coordinate falls in. None of
them touches the host — they verify headlessly, and a server or a test
can use them with no browser in sight.

**Where the rest of it is.** This chapter carries the interface and, for
each name, the one thing about it that is easy to get wrong. The
reasoning behind each decision, the measurements, and the alternatives
that were rejected are in `docs/simulation.md`, and every section below
ends with a pointer to it. The split is deliberate: an argument gets
rewritten as it is understood better, an interface does not, so keeping
both in one place would guarantee that the two copies drifted.

### `(sim entity)`: Who Exists

```
procedure: (make-entities capacity)

func -> int -> *entities
```
A store of at most `capacity` entities. Running out **raises** rather
than growing: the moment a simulation stops being bounded is worth
knowing about.

```
procedure: (entity-spawn! w)
procedure: (entity-spawn-with! w rows)

func -> *entities -> list -> pair
```
A handle: the slot, paired with the generation that slot was on.
`entity-spawn-with!` takes `((name . value) …)` and makes an entity
carrying all of them; the row shapes, the names and any repeat among
them are checked **before anything is created**, so a refusal costs no
entity. It takes **values, not factories** — a factory reaches the host,
and a host exception is not a Scheme condition here, so a rollback
wrapped around factories would fail exactly when it was needed.

```
procedure: (entity-alive? w h)
procedure: (entity-destroy! w h)

func -> *entities -> pair -> boolean
```
Destroying advances the generation of the slot, so **every copy of the
old handle stops matching permanently** — the one in a scheduler, the
one in an event payload, the one someone saved. This is the thing an
index cannot do: an index into a live array is always "valid", so the
day its slot is reused every stale copy starts addressing a stranger,
with no error and nothing to notice. Destroying twice is quiet.

```
procedure: (entity-set! w h key value)
procedure: (entity-ref w h key default)

func -> *entities -> pair -> symbol -> any -> any
```
**Writing through a dead handle raises; reading through one answers the
default.** Writing to something that no longer exists is a mistake in
the caller; asking whether something is still there is not.

```
procedure: (entity-each w proc)
procedure: (entity-count w)   (entity-capacity w)

func -> *entities -> procedure -> void
```
`entity-each` walks a snapshot: entities destroyed during the walk are
skipped, and entities spawned during it are visited on the **next** walk.
Without that, spawning from inside a walk could extend it forever.

Components are a small association per entity: right for hundreds of
entities, wrong for hundreds of thousands. That is a sizing question,
and it is here rather than in the long form because a reader answers it
when choosing the library, not when reading about it. If someone
measures a need for an index, adding one does not change this
interface.

Long form in `docs/simulation.md`.

### `(sim schedule)`: What Runs Each Tick

```scheme
(define s (make-schedule))
(schedule-add! s 'input 0 (lambda (ctx dt) ...))
(schedule-add! s 'physics 10 (lambda (ctx dt) ...))
(schedule-run! s world 0.016)
```

```
procedure: (make-schedule)
procedure: (schedule-add! s id priority proc)
procedure: (schedule-remove! row)
procedure: (schedule-systems s)

func -> *schedule -> symbol -> int -> procedure -> *system
```
**Order comes from the priority number, never from load order**, and
equal priorities keep the order they were added in — including across
removals, because the tie is broken by a stored sequence number rather
than by position in a list. An order that comes from load order is
invisible in the source and changes when someone renames a file.
`schedule-add!` answers a row token for `schedule-remove!`; a second
live system under an id already in use is an error. Removal takes effect
immediately, even inside a tick that is already walking the list.

```
procedure: (schedule-run! s context dt)

func -> *schedule -> any -> number -> void
```
**A system that raises stops the tick**, and the condition reaches the
caller — a tick is one transition of the whole world, and continuing
past a failed system leaves a half-updated state that looks complete.
Running the schedule from inside a system is an error by name, and the
flag is restored if a system raises, so one bad tick does not wedge the
schedule forever.

Long form in `docs/simulation.md`.

### `(sim events)`: Who Hears What

```
procedure: (make-bus)
procedure: (bus-on! b topic proc)
procedure: (bus-off! token)
procedure: (bus-clear! b)

func -> *bus -> symbol -> procedure -> *subscription
```
Listeners hear a topic in the order they subscribed. `bus-on!` answers a
token; `bus-off!` takes effect **inside a running emit**, which is
exactly when a caller unsubscribes.

```
procedure: (bus-emit! b topic payload)

func -> *bus -> symbol -> any -> void
```
**Emit walks a snapshot**: the set of listeners that hears one emit is
fixed before the first of them runs, so a listener that subscribes from
inside a handler hears the *next* event and not the one that created it.
Emitting from inside a listener is allowed and bounded — past
`bus-depth-limit` it raises, naming the topic, because the natural
mistake is a listener that emits the topic it listens to and a stack
overflow does not say which two topics were feeding each other.

Long form in `docs/simulation.md`.

### `(sim step)`: Fixed Steps, Advanced by the Caller

```
procedure: (make-fixed-step step max-steps)
procedure: (fixed-step-advance! c elapsed proc)

func -> *step -> number -> procedure -> void
```
Runs the body once per whole step that is now due. **The count is
derived from the total elapsed time every call, not accumulated**, so
one frame's rounding is never carried into the next. `max-steps` caps
how many steps one advance may run: without it a stall produces a burst
of catch-up steps whose cost produces the next stall. **The body always
receives the configured step**, never a partial one, so a system may
treat its argument as a constant.

```
procedure: (fixed-step-alpha c)
procedure: (fixed-step-time c)
procedure: (fixed-step-reset! c)

func -> *step -> number
```
`fixed-step-alpha` is where the caller stands between the last simulated
state and the next, in `[0,1)`, for interpolating what is drawn.
**`fixed-step-time` is the simulated clock — steps taken times the step —
and not the sum of the frame times**; the two differ by whatever a stall
dropped, and the simulation ran on this one. `fixed-step-reset!` throws
the remainder away, so time that passed while nothing was simulated is
not owed after a pause.

Long form in `docs/simulation.md`.

### `(sim random)`: Draws a Replay Can Reproduce

```
procedure: (make-rng seed)
procedure: (random-integer! r n)
procedure: (random-real! r)
procedure: (random-range! r lo hi)

func -> *rng -> number -> number -> number
```
**The whole state is one integer the caller holds** — nothing reads a
clock, a device or a global — so the same seed replays the same
sequence and two generators never interfere. `random-integer!` takes a
positive fixnum bound; `random-range!` refuses a range that is empty in
flonum precision rather than answering its own upper end. Every draw
advances the state exactly once.

`make-rng` refuses a seed that is not a fixnum: a seed is what a replay
is written down as, and one that cannot be written down is a mistake
worth hearing about at the call.

The generator is MINSTD, period 2147483646, and **it is not
cryptographic**: two successive draws determine the state. The algorithm
is written out in `docs/simulation.md` in enough detail to implement
again, along with a published check value for the bare recurrence.

Every draw this generator makes is the same on both compiler targets: it
uses only exact integer arithmetic, and `random-real!`'s division has
both operands inside 2^31 where a flonum is exact. That is a property of
the arithmetic, not a promise this file is making on behalf of another.
(The one place the two targets do differ — `eq?` on separately computed
bignums — has nothing to do with this generator; see D2a in
`docs/determinism.md`.)

Long form in `docs/simulation.md`.

### `(sim grid)`: Which Cell Owns a Coordinate

```
procedure: (grid-cell x size)

func -> number -> number -> int
```

```
procedure: (grid-origin i size)

func -> int -> number -> number
```

```
procedure: (grid-in-cell? cx cy size x y)

func -> int -> int -> number -> number -> number -> boolean
```
**The index is a floor, not a truncation.** Truncating toward zero maps
`-0.5` and `0.5` into the same cell, which makes cell 0 twice as wide as
every other and cell `-1` an address that never occurs — and nothing
raises, so the world simply has one seam where objects pile up. Floor
and truncation agree on the positive side, which is why the bug survives
every test written in the first quadrant.

A cell size of zero or less is refused by name; the index that comes
back is an exact integer, because callers address something with it.

**Cells are half-open**, `[origin, origin + size)`, so a point exactly on
an edge belongs to the cell it *opens* and has exactly one owner. Under
a closed interval an object on a seam is loaded twice by a streamer that
unions cells and not at all by one that partitions them. The same choice
makes `grid-origin` an exact inverse: the origin of a cell is always
inside that cell, on both sides of zero.

Long form in `docs/simulation.md`.

## Current Limits and Planned Work

- **`call/cc` escape-only**: continuations can jump out but not re-enter. This is a Wasm limitation; re-entrancy would require a different implementation. The JS target lowers `call/cc` to native `throw`/`catch` and inherits the same restriction, so the two targets agree here as everywhere else.
- **Async needs JSPI**: `(web fetch)` and the direct-style `(web rpc)` suspend over Wasm JSPI, so they need an engine that has it (Chrome stable; Node with `--experimental-wasm-jspi`). Elsewhere, feature-detect with `(fetch-direct?)` and use the callback `rpc!`. The JS target cannot suspend at all—`js-await` hands the promise straight back—so its kernel hides `WebAssembly.Suspending`/`promising` from the program's view of the host: the probes answer no even in a JSPI-enabled browser, and the same feature test that picks the callback route on a wasm engine without JSPI picks it here, automatically. Nothing to special-case in your code.
- **The JS target trades speed for reach**: it is the compatibility path, not a second fast path. Flonums stay boxed, and the SIMD primitives underneath `(gfx mat)` run as scalar loops—correct, not fast. Control flow costs nothing in reach, though: self tail calls become loops and non-self tail calls trampoline (the call returns a thunk the nearest non-tail frame bounces), so mutual recursion runs in constant JS stack just as `return_call` does on wasm.
- **No datum labels**: the reader does not support `#0=` / `#0#` cyclic-structure notation.

These are design decisions, not bugs; file issues if you have use cases that need them.
