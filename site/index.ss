;; index.html — the homepage shell, authored in Scheme, rendered by
;; Goeteia. The hero inside #live is compiled and mounted live in the
;; browser from hero.ss (see index.js); everything else is static.
(import (web html) (web css) (chrome))   ; card / section* come from chrome

;; ---- the numbered feature showcases: kicker, title, lead, then a
;; text column beside a code block (flip? alternates the sides) ----
(define (show num kick title lead flip? txt code)
  `(div (@ (class "show"))
     (div (@ (class "kicker")) ,(string-append num " · " kick))
     (h2 ,title)
     (p (@ (class "slead")) ,@lead)
     (div (@ (class ,(if flip? "feature flip" "feature")))
       (div (@ (class "txt")) ,@txt)
       (pre ,(raw code)))))

;; hand-highlighted code, igropyr-style: the token classes are the
;; same ones the live editor's highlighter uses
(define r6rs-code
  "(<span class=\"tok-k\">define-syntax</span> while              <span class=\"tok-c\">; syntax-rules</span>
  (<span class=\"tok-k\">syntax-rules</span> ()
    ((_ c body ...)
     (<span class=\"tok-k\">let</span> loop ()
       (<span class=\"tok-k\">when</span> c body ... (loop))))))

(<span class=\"tok-k\">define-syntax</span> inc!               <span class=\"tok-c\">; procedural syntax-case</span>
  (<span class=\"tok-k\">lambda</span> (x)
    (<span class=\"tok-k\">syntax-case</span> x ()
      ((_ v)   #'(<span class=\"tok-k\">set!</span> v (+ v <span class=\"tok-n\">1</span>)))
      ((_ v n) #'(<span class=\"tok-k\">set!</span> v (+ v n))))))

(fact <span class=\"tok-n\">20</span>)  <span class=\"tok-c\">; =&gt; 2432902008176640000 -- exact</span>
(/ <span class=\"tok-n\">1</span> <span class=\"tok-n\">3</span>)    <span class=\"tok-c\">; =&gt; 1/3 -- a rational, not 0.333…</span>")

(define webdsl-code
  "(<span class=\"tok-k\">define</span> (card title . body)       <span class=\"tok-c\">; UI is a function</span>
  `(div (@ (class <span class=\"tok-s\">\"card\"</span>))
     (h3 ,title) (p ,@body)))

(<span class=\"tok-h\">css-&gt;string</span>                       <span class=\"tok-c\">; CSS is a list</span>
 `((.card (background (var bg2))
          (border-radius (px <span class=\"tok-n\">12</span>)))))
<span class=\"tok-c\">;; =&gt; \".card{background:var(--bg2);border-radius:12px}\"</span>

(<span class=\"tok-k\">sx</span> (button (@ (on-click ,bump!))  <span class=\"tok-c\">; a macro: the static</span>
      <span class=\"tok-s\">\"clicked \"</span> ,(<span class=\"tok-h\">signal-ref</span> n)))  <span class=\"tok-c\">; tree is built ONCE,</span>
                                    <span class=\"tok-c\">; holes become effects</span>")

(define typeset-code
  "<span class=\"tok-c\">;; (web dom): the browser, as ordinary calls</span>
(<span class=\"tok-k\">define</span> el (<span class=\"tok-h\">create-element</span> <span class=\"tok-s\">\"span\"</span>))
(<span class=\"tok-h\">set-text!</span> el <span class=\"tok-s\">\"the glyph\"</span>)
(<span class=\"tok-h\">append-child!</span> (<span class=\"tok-h\">get-element-by-id</span> <span class=\"tok-s\">\"live\"</span>) el)

<span class=\"tok-c\">;; (web typeset), after pretext: measure once,</span>
<span class=\"tok-c\">;; then layout is pure arithmetic -- no DOM</span>
(<span class=\"tok-k\">define</span> l
  (<span class=\"tok-h\">layout</span> (<span class=\"tok-h\">prepare</span> text (<span class=\"tok-h\">canvas-measurer</span> font))
          max-width line-height))

(<span class=\"tok-h\">layout-height</span> l)   <span class=\"tok-c\">; known BEFORE anything renders</span>
(<span class=\"tok-h\">for-each</span> place-line! (<span class=\"tok-h\">layout-lines</span> l))")

(define shader-code
  "(<span class=\"tok-k\">define</span> sky-p
  (<span class=\"tok-h\">fx-program!</span>
   '((attribute vec3 a_pos)
     (uniform mat4 u_vp)
     (varying vec3 v_dir)
     (<span class=\"tok-k\">define</span> (main) void
       (<span class=\"tok-k\">set!</span> v_dir a_pos)
       (local vec4 p (* u_vp (vec4 a_pos (fl <span class=\"tok-n\">0</span>))))
       (<span class=\"tok-k\">set!</span> gl_Position p.xyww)))  <span class=\"tok-c\">; the sky never moves</span>
   '((precision mediump float)
     (uniform samplerCube u_sky)
     (varying vec3 v_dir)
     (<span class=\"tok-k\">define</span> (main) void
       (<span class=\"tok-k\">set!</span> gl_FragColor (textureCube u_sky v_dir))))))")

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
          (button (@ (id "run") (disabled #t)) "Run")
          (span (@ (id "status") (class "status")) "booting the compiler…"))
        (p (@ (class "hint"))
           "No server compiles this — the page carries the whole compiler ("
           (code "goeteia.wasm") ", ~38 KB gzipped, cached after first load), "
           "and each Run recompiles the source above in ~15 ms.")))

   `(section (@ (id "showcase"))
      ,(show "01" "The language" "R6RS and syntax-case, complete — in the page"
         '("Not a toy subset: hygienic " (code "syntax-rules") " and "
           "procedural " (code "syntax-case") " with fenders, nested "
           "ellipses and " (code "datum->syntax") ", compiled to Wasm GC "
           "right here in your browser.")
         #f
         '((h3 "The whole standard, running above")
           (p "Exact bignums and rationals, " (code "call/cc") " and "
              (code "dynamic-wind") " on Wasm's own exception handling, "
              "and every tail call a " (code "return_call") " — a "
              "hundred-million-iteration loop runs in "
              (b "constant stack") ".")
           (p "The expander is a compile-time interpreter with hygiene by "
              "renaming: a macro's bindings and yours can never collide. "
              "Paste any of this into the editor above and press Run."))
         r6rs-code)
      ,(show "02" "The web as list" "Macros expand into HTML and CSS"
         '("A document is a tree; a stylesheet is a list of rules — the "
           "exact shapes s-expressions were made for. " (code "(web html)")
           " and " (code "(web css)") " are two pure functions over one "
           "representation, and " (code "(web sx)") " is a macro over it.")
         #t
         '((h3 "The page you're reading is the proof")
           (p "Every element and every CSS rule of this site expands from "
              "Scheme — " (code "site/index.ss") " is the whole page; the "
              (b "\"Built in pure Scheme\"") " badge shows you the source. "
              "A colour is one binding shared by styles and code; DRY is "
              (code "append") ".")
           (p "The " (code "sx") " template macro splits at expansion "
              "time: the static tree is built once, each unquote becomes a "
              "hole wired to a signal — one text node updates, and "
              (b "nothing re-renders") ". No virtual DOM, no diffing."))
         webdsl-code)
      ,(show "03" "Text & the DOM" "Typesetting without a layout engine"
         '((code "(web dom)") " wraps the browser in ordinary procedures. "
           (code "(web typeset)") " — after "
           (a (@ (href "https://www.pretext.cool")) "pretext")
           " — takes the layout engine " (em "out") " of the browser: "
           "measure each distinct code point once, then layout is a pure "
           "function from metrics to line boxes.")
         #f
         '((h3 "Layout you can compute, not await")
           (p "Heights are known " (b "before") " anything touches the DOM "
              "— virtual scrolls and streaming chat stop guessing — and "
              "text can be set where no layout engine exists at all: "
              "canvas and WebGL scenes. Greedy first-fit breaking with CJK "
              "kinsoku — closing punctuation never starts a line.")
           (p "It is at work on this site: the hero's subtitle and the "
              (b "Why Scheme?") " page's headings are set glyph by glyph "
              "by " (code "(web typeset)") " — which is why they can dodge "
              "your cursor."))
         typeset-code)
      ,(show "04" "Graphics" "3D, from s-expressions"
         '((code "(gfx gl)") " drives WebGL 2 through a command buffer — "
           "shadow maps, PBR, HDR bloom, SSAO, instancing, skeletal "
           "animation from glTF — and " (code "(gfx glsl)") " renders "
           "shaders written as s-expressions to either GLSL dialect.")
         #t
         '((h3 "This exact program runs above")
           (p "It is the sky of the " (code "skybox.ss") " tab in the live "
              "editor — switch to it, edit a form, press Run. The mirror "
              "floor of " (code "pointlight.ss") " and the WebGPU fire of "
              (code "particles.ss") " — a hundred thousand particles whose "
              "physics is a compute shader — are tabs beside it.")
           (p "Because a shader is a datum, " (b "macros can write shaders")
              ": the hero's twelve thousand particles run their physics in "
              "a vertex shader assembled by Scheme."))
         shader-code))

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

(write-file "index.html"
  (render-page "Goeteia — a page that compiles itself"
               (string-append "The Goeteia homepage renders itself: its Scheme "
                              "source is compiled to WebAssembly in your browser and "
                              "mounted live. Edit the source, press Run, and the page "
                              "below re-renders.")
               (string-append
                 (css->string (base-styles 60))
                 (read-file "site/index.css")
                 (css->string (footer-styles)))
               'index "site/index.ss" body
               (list '(script (@ (type "module") (src "index.js"))))))
