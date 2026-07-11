# Goeteia

*Γοητεία — sorcery.  A self-hosting Scheme for the WebAssembly GC era.*

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

See `docs/design.md` for the object representation, the calling
convention, and the milestone-by-milestone build log.

## Self-hosting

```
$ ./build-self.sh
stage1: Chez-hosted compiler compiling the compiler...
stage2: self-hosted compiler compiling the compiler...
fixpoint: stage1 == stage2
```

`schwasm-self.wasm` is the compiler as a Wasm GC module: it reads
Scheme source on its input byte stream and writes a Wasm module to
its output.  Stage 1 (built by the Chez-hosted compiler) compiling
the compiler reproduces itself exactly; the test suite runs every
test through both stages.

## Usage

Compiling requires [Chez Scheme](https://cisco.github.io/ChezScheme/)
or the checked-in `schwasm-self.wasm`; running requires Node 22+ or
any Wasm GC engine.

```
$ ./bin/schwasmc program.ss program.wasm        # Chez-hosted
$ node rt/compile.mjs schwasm-self.wasm program.ss program.wasm
$ node rt/run.mjs program.wasm
```

A program is a sequence of top-level definitions and expressions; the
value of the last expression is printed.

```scheme
(define (fact n)
  (if (zero? n) 1 (* n (fact (- n 1)))))
(fact 20)          ; prints 2432902008176640000
```

## Playground

Serve the repo root (`python3 -m http.server`) and open
`playground.html`: the self-hosted compiler — a Wasm GC module — runs
in the browser and compiles what you type; no server-side anything.

## Tests

```
$ ./run-tests.sh
```

Each file in `test/` declares its expected output in its first line
and runs through both the Chez-hosted and the self-hosted compiler.

## License

MIT.  See LICENSE.
