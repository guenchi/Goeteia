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
| fixnum        | `i31ref`, value `n << 1` (30-bit, unboxed)         |
| bignum        | `(struct i32-sign (ref $vector))`, 14-bit limbs; fixnum arithmetic promotes on overflow (bits 30/31 disagree after a tagged add/sub; products checked in i64) |
| flonum        | `(struct f64)`; contagion via prelude generics, IEEE-754 bits for literals computed in pure Scheme so both hosts emit identical bytes |
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

The only host import is `io.write_byte`; the runtime library
(`display`, `string=?`, ...) is written in schwasm's own Scheme
(`src/prelude.ss`) and compiled into every module, with user
definitions overriding same-named prelude definitions.

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

The compiler is written in the subset of Scheme that it compiles.
Chez Scheme hosts it for bootstrapping; the self-hosted build
(`build-self.sh`) compiles the compiler with itself and checks that
the result is a byte-identical fixpoint.

## Program shape

A schwasm program is a sequence of top-level definitions and
expressions.  Expressions run in order; the value of the last one is
the program's result, exported as `main`.

## Calling convention

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

## Roadmap

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
  schwasm's own Scheme.
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
  subset schwasm compiles.  `src/chez-driver.ss` hosts it under Chez
  (stage0); `src/wasm-driver.ss` appended to `src/compiler.ss` and
  compiled by stage0 yields `schwasm-self.wasm` (stage1), a wasm
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
