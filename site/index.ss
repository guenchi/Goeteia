;; index.html — the homepage shell, authored in Scheme, rendered by
;; Goeteia. The hero inside #live is compiled and mounted live in the
;; browser from hero.ss (see index.js); everything else is static.
(import (web html) (web css) (web component) (chrome) (hl))

;; a titled box: markup and its css in ONE form; every card on the
;; page interns to the same generated class
(define-component (card title . body)
  (style (background (var bg2)) (border (px 1) solid (var line))
         (border-radius (px 10)) (padding (em 1 10) (em 1 20))
         (box-shadow "0 1px 3px rgba(16,20,42,.06)")
         ("h3" (margin 0 0 (em 0 40)) (font-size (em 1))
               (color (var lapis)) (font-weight 600))
         ("p" (margin 0) (color (var dim)) (font-size (em 0 92)))
         ("code" (font-family (var mono)) (color (var lapis))
                 (font-size (em 0 90))))
  (div (h3 ,title) (p ,@body)))

;; the Run button: its css lives on it, pseudo-classes included
(define-component (run-button)
  (style (font-size (px 15)) (padding (em 0 45) (em 2))
         (border-radius (px 6)) (background (var lapis))
         (color "#fff") (border none) (font-weight 600)
         (cursor pointer) (min-width (em 7))
         (:hover (filter "brightness(1.1)"))
         (:disabled (opacity (dec 0 50)) (cursor default)))
  (button (@ (id "run") (disabled #t)) "Run"))

;; ---- the numbered feature showcases: kicker, title, lead, then a
;; text column beside a code block (flip? alternates the sides) ----
(define-component (show num kick title lead flip? txt code)
  ;; the showcase block's whole shape -- kicker, title, the text|code
  ;; feature grid, its responsive single-column fallback -- lives with
  ;; it; the six calls intern to one class
  (style
    (padding (em 1 80) 0 (em 0 80))
    (".kicker" (font-family (var mono)) (font-size (em 0 76)) (font-weight 600) (letter-spacing (em 0 16)) (text-transform uppercase) (color (var azure)))
    ("h2" (font-size (em 1 55)) (margin (em 0 25) 0 (em 0 40)) (letter-spacing "-.01em"))
    (".slead" (color (var dim)) (font-size (em 1 5)) (max-width (em 44)) (margin 0))
    (".slead code" (font-family (var mono)) (color (var lapis)) (font-size (em 0 88)) (background "#eef1f9") (padding (em 0 5) (em 0 35)) (border-radius (px 4)))
    (".feature .txt code" (font-family (var mono)) (color (var lapis)) (font-size (em 0 88)) (background "#eef1f9") (padding (em 0 5) (em 0 35)) (border-radius (px 4)))
    (".feature" (display grid) (grid-template-columns "1fr 1fr") (gap (em 2 60)) (align-items center) (margin-top (em 1 40)))
    (".feature > *" (min-width 0))
    (".feature.flip .txt" (order 2))
    (".feature h3" (font-size (em 1 12)) (margin 0 0 (em 0 50)))
    (".feature h4" (font-size (em 1)) (margin (em 1 20) 0 (em 0 50)))
    (".feature p" (color (var dim)) (font-size (em 0 95)) (margin 0 0 (em 0 70)))
    (".feature p b" (color (var ink)))
    (".feature ul.points" (list-style none) (padding 0) (margin 0 0 (em 0 70)))
    (".feature ul.points > li"
     (position relative) (padding-left (em 1 30)) (margin (em 0 50) 0) (color (var dim)) (font-size (em 0 95)))
    (".feature ul.points > li::before"
     (content "\"→\"") (position absolute) (left 0) (color (var azure)) (font-weight 700))
    (".feature ul.points b" (color (var ink)))
    (".feature pre" (background (var bg2)) (border (px 1) solid (var line)) (border-radius (px 10)) (padding (em 1 10) (em 1 20)) (overflow-x auto) (font-family (var mono)) (font-size (px 12 50)) (line-height (dec 1 55)) (color (var ink)) (margin 0) (box-shadow 0 (px 1) (px 3) (rgba 16 20 42 (dec 0 6))))
    ,@(hl-styles ".feature pre")
    (@media 64
      (".feature" (grid-template-columns "1fr") (gap (em 1 20)))
      (".feature.flip .txt" (order 0))))
  (div
    (div (@ (class "kicker")) ,(string-append num " · " kick))
    (h2 ,title)
    (p (@ (class "slead")) ,@lead)
    (div (@ (class ,(if flip? "feature flip" "feature")))
      (div (@ (class "txt")) ,@txt)
      (pre ,(raw code)))))

;; the code samples, as plain text; (hl)'s build-time highlighter
;; paints them with the same token classes the live editor uses
(define r6rs-code (highlight
"(define-syntax while              ; syntax-rules
  (syntax-rules ()
    ((_ c body ...)
     (let loop ()
       (when c body ... (loop))))))

(define-syntax inc!               ; procedural syntax-case
  (lambda (x)
    (syntax-case x ()
      ((_ v)   #'(set! v (+ v 1)))
      ((_ v n) #'(set! v (+ v n))))))

(fact 20)  ; => 2432902008176640000 -- exact
(/ 1 3)    ; => 1/3 -- a rational, not 0.333…"))

(define webdsl-code (highlight
";; one form: the markup AND its css -- this is the
;; real definition of the cards further down this page
(define-component (card title . body)
  (style (background (var bg2))
         (border-radius (px 10))
         (\"h3\" (color (var lapis))))   ; descendants,
  (div (h3 ,title) (p ,@body)))       ; :hover, @media…

;; equal style sets intern to ONE generated class:
;; nine cards below share a single rule

(sx (button (@ (on-click ,bump!))  ; live holes: the
      \"clicked \" ,(signal-ref n)))  ; tree builds ONCE,
                                    ; holes become effects"))

(define typeset-code (highlight
";; (web dom): the browser, as ordinary calls
(define el (create-element \"span\"))
(set-text! el \"the glyph\")
(append-child! (get-element-by-id \"live\") el)

;; (web typeset), after pretext: measure once,
;; then layout is pure arithmetic -- no DOM
(define l
  (layout (prepare text (canvas-measurer font))
          max-width line-height))

(layout-height l)   ; known BEFORE anything renders
(for-each place-line! (layout-lines l))"))

(define shader-code (highlight
"(define sky-p
  (fx-program!
   '((attribute vec3 a_pos)
     (uniform mat4 u_vp)
     (varying vec3 v_dir)
     (define (main) void
       (set! v_dir a_pos)
       (local vec4 p (* u_vp (vec4 a_pos (fl 0))))
       (set! gl_Position p.xyww)))  ; the sky never moves
   '((precision mediump float)
     (uniform samplerCube u_sky)
     (varying vec3 v_dir)
     (define (main) void
       (set! gl_FragColor (textureCube u_sky v_dir))))))"))

(define fallback-code (highlight
";; one source -> wasm AND its JS fallback, loader inlined
(define-wasm-js (app \"app.wasm\")
  (import (app))
  (run-app))

;; capability gate: another mount point, in Scheme too
(define-js hero-gate
  (import (web js) (web dom))
  (when (webgl2? canvas)               ; probe, reveal, measure
    (js-call (js-get (js-global) \"__goeteia_load\")
             (js-undefined) \"/anim.wasm\")))"))

(define rpc-code (highlight
";; (web rpc): the wire carries a datum
(rpc \"/rpc\" '(add 1 2 1/2))     ; => (ok 7/2) -- exact
(ws-connect! \"/live\" (lambda (msg) ...))

;; the server (Igropyr): a dialogue is ONE process,
;; parked at a line by its continuation
(conversation-start!
  (lambda (req suspend!)
    (let ((req2 (suspend! confirm-page)))  ; round-trip;
      (commit!)                            ; resumes HERE
      done))
  req)

(conversation-resume! id req2)  ; => reply | 'gone
;; 'gone means: rolled back. guaranteed."))

(define body
  (list
   `(div (@ (class "cols"))
      (div (@ (id "live")))                 ; the hero mounts here
      (section (@ (id "editor"))
        (p (@ (class "lead"))
           (b "Everything beside this is live rendered by Goeteia.") (br)
           "The Scheme below is compiled to WebAssembly " (em "in your browser")
           " and mounted live.")
        (div (@ (class "tabs") (id "tabs")))
        (div (@ (class "code"))
          (pre (@ (class "hl") (id "hl") (aria-hidden "true")))
          (textarea (@ (id "src") (rows "18") (spellcheck "false")
                       (autocapitalize "off") (autocorrect "off")) "loading…"))
        (div (@ (class "bar"))
          ,(run-button)
          (span (@ (id "status") (class "status")) "booting the compiler…"))
        (p (@ (class "hint"))
           "No server compiles this — the page carries the whole compiler ("
           (code "goeteia.wasm") ", ~50 KB gzipped, cached after first load), "
           "and each Run recompiles the source above in about 80 ms.")))

   `(section (@ (id "showcase"))
      ,(show "01" "The language" "R6RS and syntax-case, complete and in-page"
         '("This is not a toy subset. Goeteia ships full hygienic "
           (code "syntax-rules") " and procedural " (code "syntax-case")
           "—complete with fenders, nested ellipses, and "
           (code "datum->syntax") ". It compiles directly to Wasm GC, right "
           "here in your browser.")
         #f
         '((p "The macro expander is a full compile-time interpreter. It "
              "enforces hygiene by renaming: a macro's internal bindings and "
              "your lexical scope can physically never collide.")
           (h3 "The full standard, running live")
           (p "Goeteia implements the standard without compromises.")
           (ul (@ (class "points"))
             (li (b "The Math Tower:") " Exact rationals and bignums compute "
                 "seamlessly.")
             (li (b "Native Continuations:") " " (code "call/cc") " and "
                 (code "dynamic-wind") " are mapped directly onto Wasm's own "
                 "native exception handling.")
             (li (b "True TCO:") " Every tail call is a true Wasm "
                 (code "return_call") ". A hundred-million-iteration recursive "
                 "loop runs in " (b "absolute constant stack space") "."))
           (p "Paste any of this into the editor above and hit Run."))
         r6rs-code)
      ,(show "02" "The web as list" "Macros expand into HTML and CSS"
         '("A document is a tree; a stylesheet is a list of rules. These are "
           "the exact physical shapes s-expressions were invented for. "
           (code "(web html)") " and " (code "(web css)") " are just two pure "
           "functions mapping over a single, unified representation. "
           (code "(web sx)") " is the macro that drives them.")
         #t
         '((h3 "The page you're reading is the proof")
           (p "Every single DOM element and CSS rule on this site expands "
              "directly from Scheme. " (code "site/index.ss") " is the entire "
              "page. A color hex code is just a lexical binding shared "
              "seamlessly between the stylesheet and the rendering logic. In "
              "this world, DRY isn't a design pattern—DRY is just "
              (code "append") ".")
           (h4 "Surgical reactivity")
           (p "The " (code "sx") " template macro splits the tree at expansion "
              "time. The static scaffolding is built exactly once. Every "
              "unquote becomes a surgical hole wired directly to a reactive "
              "signal. When state changes, exactly one text node updates, and "
              (b "nothing else re-renders") ".")
           (p "No virtual DOM. No diffing."))
         webdsl-code)
      ,(show "03" "Text & the DOM" "Typesetting without a layout engine"
         '((code "(web dom)") " wraps the chaotic browser in predictable "
           "procedures, but " (code "(web typeset)") "—after "
           (a (@ (href "https://www.pretext.cool")) "pretext")
           "—takes it a step further: it rips the layout engine " (em "out")
           " of the browser entirely. By measuring each distinct code point "
           "exactly once, layout ceases to be a black-box browser side-effect. "
           "It becomes a pure function—a deterministic mapping from raw "
           "metrics directly to line boxes.")
         #f
         '((h3 "Layout you compute, not await")
           (p "Because layout is computed entirely in Scheme, exact heights "
              "are known " (b "before") " a single pixel touches the DOM. "
              "Virtual scrolls and streaming chats finally stop guessing and "
              "shifting. Better yet, text can now be seamlessly typeset in "
              "environments where no native layout engine exists at all: "
              "Canvas and WebGL scenes. It even ships with a greedy first-fit "
              "line breaker that strictly enforces CJK kinsoku shori (closing "
              "punctuation will physically never start a line).")
           (h4 "The proof is on the screen")
           (p "This engine is actively at work on the page you are reading. "
              "The hero's subtitle and the headings on the " (b "Why Scheme?")
              " page aren't standard text nodes—they are positioned "
              "independently, glyph by glyph, by " (code "(web typeset)") ".")
           (p "That is exactly why the letters can dodge your cursor."))
         typeset-code)
      ,(show "04" "Graphics" "Textures in Scheme, frames on the GPU"
         '("A pure-Scheme KTX2/Basis transcoder—written completely from "
           "scratch against the Khronos specs—decodes ETC1S and UASTC "
           "textures in just ~12 KB gzipped. The official C++ reference ships "
           "at 462 KB. Rendering is ruthlessly GPU-driven: a compute shader "
           "culls the frustum, compacts the surviving instances, and issues "
           "exactly one " (code "drawIndexedIndirect") " per geometry. The CPU "
           "simply steps out of the way. The entire frame is decided directly "
           "on the card.")
         #t
         '((h3 "3D out of s-expressions")
           (p "The proof is in the live editor. Switch to the "
              (code "blackhole.ss") " tab, tweak a form, and hit Run—it "
              "renders a relativistic accretion disk from 1.5 million "
              "particles whose physics is pure arithmetic in the vertex "
              "shader: each particle is just four numbers (radius, phase, "
              "height, seed), and its position is a pure function of time "
              "(Keplerian shear, with the inner disk lapping the outer).")
           (h4 "Macros that write shaders")
           (p "In Lisp, code is data. Because a shader is just another datum, "
              (b "Scheme macros can generate GPU code at expansion time")
              ". The twelve thousand particles burning in the hero section "
              "above don't run on canned scripts. Their physics run inside a "
              "vertex shader, dynamically assembled and injected by Scheme."))
         shader-code)
      ,(show "05" "Networking" "S-expressions on the wire, continuations over it"
         '("When the backend is also Scheme (like "
           (a (@ (href "https://igropyr.dev")) "Igropyr")
           "), requests and replies are pure s-expressions. There is no custom "
           "protocol to design, agree upon, or parse—the language's native "
           (code "read") " and " (code "write") " are the codec. And with "
           "continuations running on the server, an entire multi-request "
           "dialogue becomes ordinary control flow, seamlessly stretched "
           "across the network.")
         #f
         '((h3 "The conversation is the process")
           (p "A checkout wizard, a booking, a fund transfer—the flow runs as "
              (b "a single process") " whose local lexical bindings hold the "
              "conversation state. “The user is at the confirm step” literally "
              "means the remote process is parked " (b "at that exact line of "
              "code") ". A state transition that the code cannot express "
              "simply cannot happen.")
           (h4 "Datum in, datum out")
           (p "Backend death for any reason answers with " (code "gone")
              "—absolute physical proof that the transaction rolled back. On "
              "the client side, consuming this is effortless. It is all routed "
              "through " (code "(web rpc)") ": pure datum in, pure datum out, "
              "with exact mathematical rationals surviving the roundtrip "
              "completely intact.")
           (p (code "(web ws)") " and " (code "(web sse)") " push raw datum "
              "streams directly to your signals, while " (code "(web json)")
              " gracefully covers any ordinary, non-Scheme backend you might "
              "need to talk to."))
         rpc-code)

      ,(show "06" "Fallback" "The page carries its own retreat"
         '("One mount point, two physical artifacts. " (code "define-wasm-js")
           " compiles the exact same Scheme source into both WebAssembly GC "
           (em "and") " plain JavaScript, inlining a smart loader that probes "
           "the engine and routes execution on the fly. No WasmGC support in "
           "an older Safari or a restricted embedded WebView? The page "
           "instantly falls back to its JS twin. Nobody hand-maintains a "
           "secondary implementation, which means the logic physically never "
           "drifts.")
         #t
         '((h3 "Dead code is dead weight")
           (p "Crucially, this twin is ruthlessly tree-shaken. It carries only "
              "the runtime it actually reaches. The kernel ships by group, and "
              "unreached library code is simply never compiled in. Your "
              "fallback payload costs " (b "exactly what the page executes")
              ", never what the dependency tree holds.")
           (h4 "Automatic fallbacks, explicit degradations")
           (p "Goeteia strictly separates mechanical compatibility from "
              "application logic.")
           (ul (@ (class "points"))
             (li (b "Engine fallback is generated:") " Because the JS twin is "
                 "compiled from the identical AST, a differential test "
                 "mathematically holds both backends to the exact same "
                 "execution behavior.")
             (li (b "Capability degradation is written:") " What if the device "
                 "lacks WebGL2? Or a layout box? What if fetching a 4.6 MB "
                 "module is too expensive for the current connection? This is "
                 "application logic. Using another mount point, "
                 (code "define-js") ", you write explicit browser probes and "
                 "graceful rollbacks purely in Scheme, reaching the loader "
                 "through a published handle to control exactly what gets "
                 "fetched."))
           (p "The page safely degrades across any hostile environment, "
              "leaving you with absolutely zero hand-written JavaScript."))
         fallback-code))

   (section* "features" "What's inside"
      `(div (@ (class "grid"))
        ,(card "Self-hosting, to the byte"
           "The compiler is written in the Scheme subset it compiles. "
           "The self-hosted build recompiles itself and the output is "
           "byte-identical — the fixpoint is checked in CI fashion on "
           "every change, and every test runs through both stages.")
        ,(card "Native Wasm GC objects"
           "Fixnums are unboxed " '(code "i31ref") "s, pairs and records "
           "are GC structs, " '(code "eq?") " is one " '(code "ref.eq") ". "
           "No shadow heap in JavaScript: the host supplies two byte-stream "
           "imports and nothing else.")
        ,(card "Hygienic macros"
           '(code "syntax-rules") " and procedural "
           '(code "syntax-case") " with fenders, nested ellipses and "
           '(code "datum->syntax") ", running in a compile-time "
           "interpreter with hygiene by renaming.")
        ,(card "Real closures, real tail calls"
           "Typed function references with a fast per-arity entry and a "
           "generic entry per closure — variadic procedures and "
           '(code "apply") " are cheap, and every tail call is a "
           '(code "return_call") ". A 100M-iteration loop runs in "
           "constant stack, in ~150ms.")
        ,(card "call/cc & dynamic-wind"
           "Escape continuations ride the Wasm exception-handling "
           "proposal: capture is O(1), the normal path costs one try "
           "block, and winders unwind inner-to-outer on the way out.")
        ,(card "A reactive web stack"
           '(code "(web sx)") " templates over fine-grained "
           '(code "(web reactive)") " signals, an " '(code "(web html)")
           " renderer, and a " '(code "(web js)") " FFI that reaches straight "
           "into the host — this page is built with it.")
        ,(card "3D and WebGL"
           '(code "(gfx gl)") " drives WebGL 2 through a command buffer "
           "with shaders as s-expressions in "
           '(code "(gfx glsl)") ", rendered to either GLSL dialect from "
           "the same forms. Shadow maps, PBR, HDR bloom, SSAO, "
           "instancing, skeletal animation from " '(code "(gfx gltf)")
           " assets, and transform-feedback particles whose physics "
           '(em "is") " the vertex shader — the title above is twelve "
           "thousand of them dodging your cursor.")
        ,(card "Scheme-to-Scheme, no codec"
           "When the backend is also Scheme (" '(code "Igropyr")
           "), requests and replies are s-expressions — "
           '(code "(rpc \"/rpc\" '(add 1 2 1/2))") " comes back "
           '(code "(ok 7/2)") ", the exact ratio intact. "
           '(code "(web fetch)") " makes it direct-style over Wasm JSPI; "
           '(code "(web ws)") " / " '(code "(web sse)") " push datum streams; "
           '(code "(web json)") " handles everyone else.")
        ,(card "Libraries"
           "R6RS-style " '(code "(library ...)") " files with "
           '(code "(import (math utils))") " resolution, dependencies "
           "first; exports are advisory because unused code is pruned "
           "anyway.")))

   `(section (@ (id "quickstart"))
      (h2 "Quick start")
      (pre (code "$ git clone https://github.com/guenchi/Goeteia
$ cd Goeteia
$ ./run-tests.sh                # every test, both compiler stages
$ ./build-self.sh               # rebuild the compiler with itself

$ echo '(define (fact n) (if (zero? n) 1 (* n (fact (- n 1)))))
(fact 20)' > fact.ss
$ node rt/compile.mjs goeteia.wasm fact.ss fact.wasm
$ node rt/run.mjs fact.wasm
2432902008176640000"))
      (p (@ (class "hint"))
         "Compiled modules run on any engine with Wasm GC and "
         "tail calls: Node 22+, current Chrome / Firefox / Safari, wasmtime. "
         "Bootstrapping from source needs Chez Scheme; the checked-in "
         "compiler wasm works without it."))))

;; the page's own stylesheet, as (web css) data -- the raw
;; site/index.css is gone; markup and styles are one language now
(define index-styles
  `(;; the live-rendered hero (built by Goeteia, mounted into #live)
    ("#live" (min-height (em 15)) (padding (em 3 50) 0 (em 1)))
    (".hero" (text-align center))
    (".hero h1"
     (font-family "\"Times New Roman\", Times, serif")
     (font-size (em 4)) (margin 0) (font-weight 400) (letter-spacing (em 0 2))
     (background "linear-gradient(120deg, var(--lapis), var(--azure))")
     (-webkit-background-clip text) (background-clip text) (color transparent))
    (".hero .tagline" (color (var dim)) (font-size (em 1 20)) (margin-top (em 0 70)))
    (".hero .gname" (color (var azure)) (font-weight 600))
    (".hero .sub" (color (var dim)) (margin-top (em 0 20)))
    (".hero .cmd"
     (display inline-block) (margin (em 1 40) auto 0) (padding (em 0 70) (em 1 20))
     (background "#eef1f9") (border (px 1) solid (var line)) (border-radius (px 8))
     (font-family (var mono)) (font-size (px 14)) (color (var ink)))
    (".hero .links" (margin-top (em 1 60)))
    (".hero .btn"
     (display inline-block) (margin 0 (em 0 40)) (padding (em 0 55) (em 1 50))
     (border (px 1) solid (var line)) (border-radius (px 6)) (color (var ink)) (font-weight 600))
    (".hero .btn.primary" (background (var lapis)) (color "#fff") (border-color (var lapis)))
    (".hero .btn:hover" (text-decoration none) (border-color (var lapis)))
    ;; the editor: the page's own source
    ("#editor" (padding (em 2) 0 (em 4)) (border-top (px 1) solid (var line)) (scroll-margin-top (em 4)))
    (".lead" (color (var dim)) (font-size (em 0 95)) (margin 0 0 (em 1)))
    (".lead b" (color (var ink)))
    ;; a colored <pre> under a transparent <textarea>; identical box
    ;; metrics keep the glyphs aligned
    (".tabs" (display flex) (gap (em 0 40)) (margin 0 0 (px -1)))
    (".tabs .tab"
     (flex 1 1 0) (min-width 0) (text-align center)
     (white-space nowrap) (overflow hidden) (text-overflow ellipsis)
     (font-family (var mono)) (font-size (px 12)) (padding (em 0 30) (em 0 80))
     (border (px 1) solid (var line)) (border-radius (px 6) (px 6) 0 0)
     (background "#eef1f9") (color (var dim)) (cursor pointer))
    (@media "(max-width: 36em)"
      (".tabs" (gap (em 0 25)))
      (".tabs .tab" (font-size (px 10 50)) (padding (em 0 30) (em 0 25))))
    (".tabs .tab.active"
     (background "#fff") (color (var ink)) (border-bottom-color "#fff") (font-weight 600))
    (".code" (position relative))
    (".code textarea, .code .hl"
     (margin 0) (padding (em 1)) (border (px 1) solid transparent) (border-radius (px 8))
     (font-family (var mono)) (font-size (px 13)) (line-height (dec 1 50)) (tab-size 2)
     (white-space pre-wrap) (overflow-wrap break-word) (word-break break-word))
    (".code .hl"
     (position absolute) (inset 0) (z-index 0) (overflow hidden)
     (border-color (var line)) (background (var bg2)) (color (var ink))
     (pointer-events none) (box-shadow inset 0 (px 1) (px 3) (rgba 16 20 42 (dec 0 6))))
    (".code textarea"
     (position relative) (z-index 1) (width (pct 100)) (display block)
     (background transparent) (color transparent) (caret-color (var ink))
     (resize vertical))
    (".code textarea:focus" (outline none))
    (".code:focus-within .hl" (border-color (var azure)))
    ,@(hl-styles ".hl")
    (".bar" (display flex) (gap (em 0 90)) (align-items center) (margin (em 0 90) 0 0) (flex-wrap wrap))
    (".status" (font-family (var mono)) (font-size (em 0 82)) (color (var dim)))
    (".status.err" (color "#b0483f"))
    (".hint" (color (var dim)) (font-size (em 0 85)) (margin-top (em 0 50)))
    (".hint code" (background "#eef1f9") (padding (em 0 10) (em 0 40)) (border-radius (px 5)) (font-family (var mono)))
    ;; the numbered feature showcases: kicker + title + text|code
    ("#showcase" (border-top (px 1) solid (var line)) (padding (em 1 20) 0 (em 2)) (max-width (em 66)) (margin 0 auto))
    ;; informational sections below the hero
    ("#features, #quickstart" (padding (em 2 50) 0) (border-top (px 1) solid (var line)) (scroll-margin-top (em 4)))
    (h2 (font-size (em 1 50)) (font-weight 600))
    (".grid" (display grid) (grid-template-columns "repeat(auto-fit, minmax(16em, 1fr))") (gap (em 1)) (margin-top (em 1 40)))
    (@media "(min-width: 64em)" (".grid" (grid-template-columns "repeat(3, 1fr)")))
    ("#quickstart p code" (font-family (var mono)) (color (var lapis)) (font-size (em 0 90)))
    ("#quickstart pre"
     (background "#eef1f9") (border (px 1) solid (var line)) (padding (em 0 90))
     (border-radius (px 8)) (white-space pre-wrap) (font-family (var mono))
     (font-size (px 13)) (overflow-x auto) (color (var ink)))
    ;; wide screens: hero on the left, the live editor on the right
    (@media "(min-width: 64em)"
      (".wrap" (max-width (em 84)))
      (".cols" (display grid) (grid-template-columns "minmax(0, 1fr) minmax(0, 1.1fr)") (gap 0 (em 3)) (align-items start))
      (".cols > *" (min-width 0))
      ("#live" (text-align left) (padding-top (em 9)))
      (".hero" (text-align left))
      (".hero .cmd" (margin-left 0))
      ("#editor" (border-top none) (padding-top (em 3 40))))))

(write-file "index.html"
  (render-page "Goeteia — a page that compiles itself"
               (string-append "The Goeteia homepage renders itself: its Scheme "
                              "source is compiled to WebAssembly in your browser and "
                              "mounted live. Edit the source, press Run, and the page "
                              "below re-renders.")
               (string-append
                 (css->string (base-styles 60))
                 (css->string index-styles)
                 (css->string (styled-css))   ; the element-attached styles
                 (css->string (footer-styles)))
               'index "site/index.ss" body
               (list '(script (@ (type "module") (src "index.js"))))))
