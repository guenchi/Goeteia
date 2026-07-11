# schwasm

A Scheme-to-WebAssembly compiler built on the WebAssembly GC
extension (Wasm 3.0).

Scheme values live in the Wasm engine's garbage-collected heap:
fixnums are unboxed `i31ref`s, pairs are GC structs, and `eq?` is a
single `ref.eq` instruction.  Compiled modules contain no host-side
object representation at all — the host is needed only for I/O — so
they run on any engine with Wasm GC and tail calls (Node 22+, current
Chrome / Firefox / Safari, wasmtime).

Proper tail calls compile to `return_call`.

## Status

Milestone 2: closures (typed function references, `call_ref`),
`set!` with assignment conversion, top-level variables, first-class
top-level functions, and the derived forms `and` `or` `not` `when`
`unless` `cond` `let*` `letrec` `letrec*` named-`let` `do`, on top of
the M1 base (fixnums, booleans, pairs, `quote`, arithmetic,
`if`/`let`/`begin`, direct and tail calls).  Tail calls through
closures use `return_call_ref`, so loops built from named `let` run
in constant stack.  See `docs/design.md` for the object
representation, pipeline, and roadmap.

## Usage

Compiling requires [Chez Scheme](https://cisco.github.io/ChezScheme/)
as the host (until schwasm is self-hosting); running requires Node 22+
or any Wasm GC engine.

```
$ ./bin/schwasmc program.ss program.wasm
$ node rt/run.mjs program.wasm
```

A program is a sequence of top-level definitions and expressions; the
value of the last expression is printed.

```scheme
(define (fact n)
  (if (< n 1) 1 (* n (fact (- n 1)))))
(fact 5)          ; prints 120
```

## Tests

```
$ ./run-tests.sh
```

Each file in `test/` declares its expected output in its first line.

## License

MIT.  See LICENSE.
