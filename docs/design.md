# schwasm design

schwasm is a Scheme-to-WebAssembly compiler built on the WebAssembly
GC extension (Wasm 3.0).  It is an independent implementation written
from the R6RS and WebAssembly specifications.

## Why Wasm GC

Pre-GC Scheme-on-Wasm systems had to keep the heap on the host side
(every pair a JS object, every `car` a wasm→JS call) or roll their own
GC in linear memory.  Wasm GC removes both compromises: the engine's
collector manages our objects, and every primitive operation is a
plain wasm instruction.  The compiled modules need a host only for
I/O, so they run in browsers, Node, and standalone runtimes alike.

## Object representation

The universal value type is `eqref` (all Scheme values support `eq?`,
which compiles to `ref.eq`).

| Scheme value  | representation                                     |
|---------------|----------------------------------------------------|
| fixnum        | `i31ref` (31-bit, unboxed)                         |
| boolean, `()`, eof, unspecified | singleton structs held in globals |
| pair          | `(struct (field mut eqref) (field mut eqref))`     |
| character     | planned: `i31ref` with a tag bit, or a struct      |
| string        | planned: `(array mut i8)` (UTF-8)                  |
| symbol        | planned: struct wrapping a string, interned        |
| closure       | planned: struct of code ref + captured environment |

Type checks are `ref.test`; field access casts with `ref.cast`.
Booleans are identity-compared against the `$false` singleton, so
truthiness is one `ref.eq`.

## Compiler pipeline

```
source forms
  → expand      (macros: derived forms now, syntax-case later)
  → analyze     (top-level defines vs. program expressions)
  → codegen     (per function: expression tree → instruction list)
  → emit        (instruction list → binary module)
```

The compiler is written in R6RS Scheme and runs under Chez Scheme as
the host.  Self-hosting (compiling itself to Wasm) is a long-term
goal; the source deliberately sticks to a small Scheme subset.

## Program shape

A schwasm program is a sequence of top-level definitions and
expressions.  Expressions run in order; the value of the last one is
the program's result, exported as `main`.

## Calling convention

Milestone 1 has direct calls only: top-level functions become wasm
functions of type `(eqref^n) → eqref`.

Closures (later milestones) will be structs carrying a typed function
reference, invoked with `call_ref`; variadic procedures will use an
argument-list convention so that arity is a runtime property, making
`apply` and rest parameters natural.

## Roadmap

- **M1 (done)**: fixnums, booleans, pairs, arithmetic, comparisons,
  `if`/`let`/`begin`/`quote`, top-level defines with direct (and tail)
  calls, binary emission, Node runner, test harness.
- **M2**: closures (`lambda`, `call_ref`), assignment conversion for
  `set!`, derived forms (`and`/`or`/`cond`/`named let`/`letrec`).
- **M3**: strings, symbols (interning), characters, `write`/`display`
  via a tiny host I/O interface.
- **M4**: a reader in Scheme, variadic procedures and `apply`,
  `values`.
- **M5**: hygienic macros (`syntax-rules`, `syntax-case` with a
  compile-time meta-interpreter, hygiene by renaming).
- **M6**: self-hosting.
