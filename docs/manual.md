# Goeteia Developer Manual

## Introduction

Goeteia is a self-hosting Scheme-to-WebAssembly-GC compiler that compiles itself and runs on any engine with Wasm GC support (Node 22+, current browsers, wasmtime). This manual documents what you need to know to build applications *on top of* Goeteia, assuming you already understand R6RS Scheme. We cover only Goeteia-specific toolchain, libraries, and behavior; standard primitives like `car`, `cdr`, `let`, and `lambda` are not documented here.

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

### Symbols and Gensym

Symbols are interned at compile time and at runtime via `string->symbol`. They are `eq?`-comparable. `gensym` takes a required prefix and appends a fresh counter:

```scheme
(gensym "var")  ; => a symbol named var0, var1, ... (prefix + counter)
```

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

## JavaScript FFI

The `(web js)` library provides the bridge to JavaScript. Scheme closures automatically become callable JS functions via the `->js` procedure and the internal `$jscb` callback protocol.

### Exports and Usage

| Function | Effect |
|----------|--------|
| `(js-ref? v)` | Test if `v` is a JS reference (externref) |
| `(js-global)` | Return `globalThis` |
| `(js-undefined)` | Return `undefined` |
| `(js-eq? a b)` | Test JS identity: `a === b` |
| `(js-truthy? v)` | Test JS truthiness |
| `(js-get obj name)` | Read property: `obj[name]` |
| `(js-set! obj name value)` | Write property: `obj[name] = value` |
| `(js-call f thisval arg1 ...)` | Call: `f.apply(thisval, [arg1, ...])` |
| `(js-method obj name arg1 ...)` | Call method: `obj[name](arg1, ...)` |
| `(js-new ctor arg1 ...)` | Construct: `new ctor(arg1, ...)` |
| `(js-index obj i)` | Array index: `obj[toString(i)]` |
| `(string->js s)` | Convert Scheme string to JS string |
| `(js->string r)` | Convert JS string to Scheme string |
| `(number->js x)` | Convert Scheme number to JS number |
| `(js->number r)` | Convert JS number to Scheme (fixnum if in range, flonum otherwise) |
| `(->js v)` | Convert any Scheme value to JS (closures become functions, true/false/nil map to JS equivalents) |
| `(js-eval code)` | Eval a string: `eval(code)` in the global scope |

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

The `(web dom)` library provides convenient wrappers for DOM operations:

| Function | Effect |
|----------|--------|
| `(window)` | Return `globalThis` |
| `(document)` | Return `globalThis.document` |
| `(body)` | Return `document.body` |
| `(get-element-by-id id)` | `document.getElementById(id)` |
| `(query-selector sel)` | `document.querySelector(sel)` |
| `(create-element tag)` | `document.createElement(tag)` |
| `(make-text s)` | `document.createTextNode(s)` |
| `(append-child! parent child)` | Add child to parent |
| `(replace-child! parent new old)` | Replace child |
| `(insert-before! parent new ref)` | Insert before reference |
| `(remove-child! parent child)` | Remove child |
| `(remove-all-children! el)` | Clear children |
| `(set-inner-html! el s)` | `el.innerHTML = s` |
| `(inner-text el)` | Read `el.innerText` |
| `(set-text! el s)` | `el.textContent = s` |
| `(set-attribute! el name v)` | Set attribute |
| `(set-style! el prop v)` | Set CSS property on `el.style` |
| `(add-event-listener! el event handler)` | Attach event listener |
| `(console-log x)` | Log to console (converts non-strings via `write`) |
| `(alert s)` | Show alert dialog |

## Reactivity

The `(web reactive)` library implements fine-grained reactive updates: signals hold values, effects observe them, and dependency tracking is automatic.

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

## React Interop

The `(web react)` library embeds Goeteia components into a React app.

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

Three graphics libraries, layered from high to low. All share the same principle as `sx`: the scene is described as data, built once, and the rendering surface is write-only—bridge traffic is O(changes), never O(frames).

### `(web three)`: Reactive Scenes

The `s3d` template builds a Three.js scene graph the way `sx` builds DOM. Static structure is built once; unquoted attribute values become signal-driven holes updated in place. `three-loop!` pumps frames into a Scheme thunk, which drives the signals and renders.

```scheme
(import (web three) (web reactive) (web dom))

(define angle (signal 0.0))

(define world
  (s3d (scene
    (mesh (@ (geometry (box 1 1 1))
             (material (standard (@ (color "#1550c4") (metalness 0.3))))
             (rotation-y ,(signal-ref angle))
             (rotation-x ,(* 0.4 (signal-ref angle)))))
    (ambient-light (@ (intensity 0.6)))
    (directional-light (@ (intensity 1.6) (position 5 10 7))))))

(define camera (s3d (perspective-camera (@ (fov 60) (position 0 0.8 3)))))
(define renderer (three-renderer (get-element-by-id "app") 640 480))

(three-loop!
 (lambda ()
   (signal-update! angle (lambda (a) (+ a 0.02)))
   (three-render! renderer world camera)))
```

- Tags: `scene`, `group`, `mesh`, `perspective-camera`, `ambient-light`, `directional-light`, `point-light`
- Geometry specs (the `geometry` attribute): `(box w h d)`, `(sphere r ...)`, `(plane w h)`, `(cylinder ...)`, `(torus ...)`, `(cone ...)`, or a raw `js-ref`
- Material specs (the `material` attribute): `(basic|standard|phong|lambert|normal (@ (k v) ...))`
- Transform attributes: `(position x y z)`, `(rotation x y z)`, `(scale x y z)`, single-axis `position-y` / `rotation-x` / …, plus any plain JS property (`intensity`, `fov`, `visible`, …)
- `(three-renderer parent width height)` → a renderer; `(three-render! renderer scene camera)` renders one frame; `(three-loop! thunk)` calls the thunk every frame

Constructor attributes (`geometry` / `material`, a camera's `fov`, a light's `intensity`) are static; put reactive holes in the others. Uses `globalThis.THREE`, so the page loads Three.js separately. Rendering stays on the GPU; only the changed attributes cross the bridge.

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

Commands: `cmd-clear!`, `cmd-use-program!`, `cmd-bind-buffer!`, `cmd-buffer-data!`, `cmd-vertex-attrib!`, `cmd-uniform1f!`, `cmd-uniform4f!`, `cmd-draw-arrays!`, `cmd-viewport!`; primitive constants `GL-POINTS`, `GL-LINES`, `GL-TRIANGLES`, `GL-TRIANGLE-STRIP`. The JS replayer is embedded in the library as a string (injected once with `js-eval`), so there is no host-side file to ship. See `examples/gl-particles.html`—10,000 particles, one bridge call per frame.

### `(web glsl)`: Shaders as S-Expressions

`glsl->string` renders a form list to GLSL source—the `(web css)` of shaders. Shaders are lists, so they compose with `append` and abstract with functions.

```scheme
(glsl->string
 '((attribute vec2 p)
   (define (main) void
     (set! gl_Position (vec4 p (fl 0) (fl 1)))
     (set! gl_PointSize (fl 2)))))
;; => "attribute vec2 p; void main() { gl_Position = vec4(p, 0.0, 1.0); gl_PointSize = 2.0; } "
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

- `(fetch url [opts])` → response; `opts` is an alist: `((method . "POST") (body . "...") (headers . (("Content-Type" . "text/plain"))))`
- `(http-get url)` / `(http-post url body [content-type])` → the response body text
- `(response-status r)`, `(response-ok? r)`, `(response-text r)`, `(response-header r name)`
- `(fetch-direct?)` → feature-detect JSPI

JSPI needs an engine that supports it (Chrome stable; Node with `--experimental-wasm-jspi`). Without it the underlying await import is the identity—feature-detect with `(fetch-direct?)` and fall back to the callback `rpc!` below. `js-await` is only legal on the main stack, not inside a `$jscb` callback re-entered from JS.

### `(web rpc)`: S-Expression RPC to a Scheme Backend

The peer is [Igropyr](https://github.com/guenchi/Igropyr), a Scheme application server. Both ends speak Scheme, so requests and replies are s-expressions—exact integers and ratios cross the wire intact, and there is no JSON in between.

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

For pushed streams there are two thin companions, matching Igropyr's `ws-send-sexpr!` / `sse-send-sexpr!` on the server—each message is one datum:

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

```scheme
(import (web json))

(string->json "{\"user\":{\"id\":42,\"tags\":[\"a\",\"b\"]}}")
;; => (("user" ("id" . 42) ("tags" . #("a" "b"))))

(json->string '(("ok" . #t) ("n" . 42)))         ; => "{\"ok\":true,\"n\":42}"
(json-ref (string->json body) "user" "id")        ; => 42
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
