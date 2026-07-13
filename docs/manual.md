# Goeteia Developer Manual

## Introduction

Goeteia is a self-hosting Scheme-to-WebAssembly-GC compiler that compiles itself and runs on any engine with Wasm GC support (Node 22+, current browsers, wasmtime). This manual documents what you need to know to build applications *on top of* Goeteia, assuming you already understand R6RS Scheme. We cover only Goeteia-specific toolchain, libraries, and behavior; standard R6RS primitives are not documented here.

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
13. [Networking](#networking)
14. [Running in the Browser](#running-in-the-browser)
15. [Testing](#testing)
16. [Porting from JavaScript/TypeScript](#porting-from-javascripttypescript)
17. [Current Limits and Planned Work](#current-limits-and-planned-work)

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

### The Chez Path (Optional)

With [Chez Scheme](https://cisco.github.io/ChezScheme/) installed, you can compile via `./bin/schwasmc`, which may be faster locally:

```bash
./bin/schwasmc program.ss program.wasm
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

Goeteia values live in the Wasm engine's garbage-collected heap as first-class GC objects. A few aspects differ from portable Scheme:

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
staging memory and `(web gl)` command buffers rely on.

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
`document.getElementById(id)`.

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
procedure: (dispose-effect! e)

func -> *effect -> void
```
Stop effect `e` and dispose the effects it owns; it will not rerun again.

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

Two graphics libraries, from high to low. `(web gl)` shares `sx`'s principle: the frame is described as data, built once, and the rendering surface is write-only—bridge traffic is O(changes), never O(frames).

### Linear Staging Memory

Every compiled module exports one growable linear wasm memory named
`memory`, which the host also sees as `globalThis.__goeteia_mem`. Scheme
writes a frame's worth of numeric data (vertices, particles) into it, and
the host reads the *same bytes* zero-copy as a typed array (a
`Float32Array` over `exports.memory.buffer`) — collapsing tens of
thousands of bridge calls into one. It is an export, not an import, so
older hosts still instantiate newer modules. `(web gl)` below is built on
it; the byte-level accessors are internal primitives.

### `(web gl)`: Raw WebGL via a Command Buffer

For full control with no Three.js, `(web gl)` speaks WebGL through a *command buffer*: Scheme encodes a frame's GL commands as words in the shared linear memory (the staging-memory primitives, `%mem-*`) and one bridge call replays them all. Vertex data uploads zero-copy from the same memory. Resources—programs, buffers, uniform locations—are JS objects, so they live in a slot table set up once at init; commands refer to slot numbers.

```scheme
(import (web gl) (web glsl))

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

### `(web glsl)`: Shaders as S-Expressions

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

## Networking

When both ends of the wire speak Scheme, there is no codec: `write` on one side, `read` on the other. For a heterogeneous backend there is a safe JSON codec. Both run over `(web fetch)`, which turns HTTP into direct-style calls.

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

JSPI needs an engine that supports it (Chrome stable; Node with `--experimental-wasm-jspi`). Without it the underlying await import is the identity—feature-detect with `(fetch-direct?)` and fall back to the callback `rpc!` below. `js-await` is only legal on the main stack, not inside a `$jscb` callback re-entered from JS.

### `(web rpc)`: S-Expression RPC to a Scheme Backend

The peer is [Igropyr](https://github.com/guenchi/Igropyr), a Scheme application server. Both ends speak Scheme, so requests and replies are s-expressions—exact integers and ratios cross the wire intact, and there is no JSON in between. A `datum` below is any wire-safe s-expression (lists, symbols, strings, exact integers and ratios, booleans).

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
Serialize a datum to the wire text (`write`, restricted to the safe
whitelist Igropyr accepts).

```
procedure: (rpc-parse text)

func -> string -> datum
```
Parse wire text back to a datum (`read`, same safe whitelist).

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

`rpc-serialize` / `rpc-parse` expose the wire codec directly (they are `write` / `read` restricted to the safe whitelist Igropyr's parser accepts: lists, symbols, strings, exact integers and ratios, booleans).

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

The `rt/web.mjs` loader instantiates a compiled module and runs it:

```javascript
import { loadGoeteia } from './rt/web.mjs';

loadGoeteia('app.wasm');
```

The module runs in the browser main thread with full DOM access. The JS bridge (`rt/jsbridge.mjs`) handles all marshaling.

### Minimal HTML

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

### Example

See `examples/counter.html` and `examples/counter.ss`—a complete counter app. Also see `examples/react-embed.html` for embedding Goeteia widgets into a React app.

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
3. Verifies the result matches the expectation

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

## Current Limits and Planned Work

- **`call/cc` escape-only**: continuations can jump out but not re-enter. This is a Wasm limitation; re-entrancy would require a different implementation.
- **Async needs JSPI**: `(web fetch)` and the direct-style `(web rpc)` suspend over Wasm JSPI, so they need an engine that has it (Chrome stable; Node with `--experimental-wasm-jspi`). Elsewhere, feature-detect with `(fetch-direct?)` and use the callback `rpc!`.
- **No datum labels**: the reader does not support `#0=` / `#0#` cyclic-structure notation.

These are design decisions, not bugs; file issues if you have use cases that need them.
