# Goeteia

*Γοητεία — the black ars of commanding what lies beneath.*

A self-hosting Scheme for the WebAssembly GC era.

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

See `design.md` for the object representation, the calling
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
           (button (@ (on-click ,(lambda _ (signal-update! n 1+))))
             "+")))
  ```
- `(web react)` — embed Goeteia components into an existing React
  app: `react-component` registers a factory the React side wraps
  in one `useEffect` (`rt/react.mjs`); props flow in as JS objects,
  the dispose thunk flows back as a JS function

`examples/counter.html` is a page scripted entirely in Goeteia;
`examples/react-embed.html` is a React app with Goeteia widgets
inside.

## Usage

Node 22+ (or any Wasm GC engine) is all you need: the compiler ships
as `goeteia.wasm`, itself a Wasm GC module.

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
independent verifier, not a dependency (`./bin/schwasmc` uses it as a
host if you have it).

## Playground

The browser playground — the self-hosted compiler running as a Wasm
GC module, no server-side anything — lives on the
[`website` branch](https://github.com/guenchi/Goeteia/tree/website);
check it out and serve it statically, or visit the project page.

## Tests

```
$ ./run-tests.sh
```

Each file in `test/` declares its expected output in its first line
and runs through both the Chez-hosted and the self-hosted compiler.

## License

MIT.  See LICENSE.
