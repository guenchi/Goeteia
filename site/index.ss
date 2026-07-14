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
(define self-code
  "<span class=\"tok-c\">$</span> ./build-self.sh
  <span class=\"tok-c\"># stage1: the Chez-hosted compiler builds compiler.ss</span>
  <span class=\"tok-c\"># stage2: stage1 rebuilds the very same source</span>
  goeteia.wasm: 267346 bytes

<span class=\"tok-c\">$</span> cmp goeteia.wasm stage2.wasm && echo fixpoint
fixpoint
  <span class=\"tok-c\"># byte-identical -- checked on every change,</span>
  <span class=\"tok-c\"># with the whole test suite run through both stages</span>")

(define reactive-code
  "(<span class=\"tok-k\">define</span> n (<span class=\"tok-h\">signal</span> <span class=\"tok-n\">0</span>))

(<span class=\"tok-h\">sx-mount</span> (<span class=\"tok-h\">get-element-by-id</span> <span class=\"tok-s\">\"app\"</span>)
  (<span class=\"tok-k\">sx</span> (button
        (@ (on-click ,(<span class=\"tok-k\">lambda</span> (e)
                        (<span class=\"tok-h\">signal-update!</span> n
                          (<span class=\"tok-k\">lambda</span> (v) (+ v <span class=\"tok-n\">1</span>))))))
        <span class=\"tok-s\">\"clicked \"</span> ,(<span class=\"tok-h\">signal-ref</span> n) <span class=\"tok-s\">\" times\"</span>)))

<span class=\"tok-c\">;; one text node updates; nothing else re-renders</span>")

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

(define rpc-code
  "<span class=\"tok-c\">;; the backend is Igropyr: the wire carries a datum</span>
(<span class=\"tok-h\">rpc</span> <span class=\"tok-s\">\"/rpc\"</span> '(add <span class=\"tok-n\">1</span> <span class=\"tok-n\">2</span> <span class=\"tok-n\">1/2</span>))      <span class=\"tok-c\">; =&gt; (ok 7/2)</span>
<span class=\"tok-c\">;; the exact ratio survives -- no JSON in between</span>

<span class=\"tok-c\">;; push channels speak datum too</span>
(<span class=\"tok-h\">ws-connect!</span> <span class=\"tok-s\">\"/live\"</span> (<span class=\"tok-k\">lambda</span> (msg) ...))
(<span class=\"tok-h\">sse-connect!</span> <span class=\"tok-s\">\"/feed\"</span> (<span class=\"tok-k\">lambda</span> (evt) ...))")

(define macro-code
  "(<span class=\"tok-k\">define-syntax</span> swap!
  (<span class=\"tok-k\">syntax-rules</span> ()
    ((_ a b)
     (<span class=\"tok-k\">let</span> ((tmp a)) (<span class=\"tok-k\">set!</span> a b) (<span class=\"tok-k\">set!</span> b tmp)))))

(<span class=\"tok-k\">let</span> ((tmp <span class=\"tok-n\">1</span>) (x <span class=\"tok-n\">2</span>))
  (swap! tmp x)     <span class=\"tok-c\">; hygiene: the macro's tmp and</span>
  (list tmp x))     <span class=\"tok-c\">; yours never collide</span>
<span class=\"tok-c\">;; =&gt; (2 1)</span>")

(define contk-code
  "(<span class=\"tok-k\">define</span> (first-match pred xs)
  (<span class=\"tok-k\">call/cc</span>
    (<span class=\"tok-k\">lambda</span> (return)              <span class=\"tok-c\">; capture: O(1)</span>
      (<span class=\"tok-h\">for-each</span> (<span class=\"tok-k\">lambda</span> (x)
                  (<span class=\"tok-k\">when</span> (pred x) (return x)))
                xs)
      #f)))

(<span class=\"tok-k\">let</span> loop ((n <span class=\"tok-n\">100000000</span>) (acc <span class=\"tok-n\">0</span>))  <span class=\"tok-c\">; every tail call is a</span>
  (<span class=\"tok-k\">if</span> (zero? n) acc               <span class=\"tok-c\">; return_call: constant</span>
      (loop (- n <span class=\"tok-n\">1</span>) (+ acc n))))    <span class=\"tok-c\">; stack, ~150 ms</span>")

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
      ,(show "01" "Self-hosting" "The compiler compiles itself"
         '("The " (code "goeteia.wasm") " on this page was emitted by the very "
           "Scheme it compiles. Correctness isn't argued in a README — it's a "
           "fixpoint you can check with " (code "cmp") ".")
         #f
         '((h3 "Byte-identical, every change")
           (p "stage1 is the Chez-hosted compiler building "
              (code "compiler.ss") "; stage2 is that output rebuilding the "
              "same source. Equal bytes are a proof no code review can give — "
              "and the whole test suite runs through " (b "both") " stages.")
           (p "The page you are reading carries the same artifact: ~38 KB "
              "gzipped, recompiling the editor's source in your browser in "
              "~15 ms."))
         self-code)
      ,(show "02" "Reactive UI" "The page is a Scheme value"
         '("An " (code "(web sx)") " template is split at expansion time: the "
           "static structure is built once, and each unquote becomes a hole "
           "wired to a fine-grained signal.")
         #t
         '((h3 "Holes update; trees don't re-render")
           (p "An " (code "on-*") " hole becomes an event listener; every "
              "other hole is a thunk rerun inside its own "
              (code "effect") ", updating just that text node or attribute.")
           (p "The DOM is a " (b "write-only surface") " — nothing is ever "
              "read back from it. No virtual DOM, no diffing, no reconciler."))
         reactive-code)
      ,(show "03" "Graphics" "Shaders are s-expressions"
         '((code "(gfx glsl)") " renders the same forms to either GLSL "
           "dialect, and " (code "(gfx gl)") " drives WebGL 2 through a "
           "command buffer — shadow maps, PBR, HDR bloom, instancing.")
         #f
         '((h3 "This exact program runs above")
           (p "It is the sky of the " (code "skybox.ss") " tab in the live "
              "editor — switch to it, edit a form, press Run.")
           (p "Because a shader is a datum, " (b "macros can write shaders")
              ": the hero's twelve thousand particles run their physics in a "
              "vertex shader assembled by Scheme."))
         shader-code)
      ,(show "04" "Networking" "Scheme to Scheme, nothing between"
         '("When the backend is also Scheme (" (code "Igropyr") "), requests "
           "and replies are s-expressions. There is no protocol to design — "
           (code "read") " and " (code "write") " are the codec.")
         #t
         '((h3 "Datum in, datum out")
           (p "Exact rationals cross the wire intact — " (code "(ok 7/2)")
              " means seven halves, not " (code "3.5") ". "
              (code "(web fetch)") " makes calls direct-style over Wasm "
              "JSPI; " (code "(web json)") " covers every other backend.")
           (p "For the thing a program is most likely to get wrong — the "
              "codec — the best move is to " (b "delete it") "."))
         rpc-code)
      ,(show "05" "Macros" "Hygiene, industrial strength"
         '((code "syntax-rules") " and procedural " (code "syntax-case")
           " with fenders, nested ellipses and " (code "datum->syntax")
           ", running in a compile-time interpreter with hygiene by renaming.")
         #f
         '((h3 "The expander writes the code")
           (p "A macro's bindings and yours can never collide — "
              (code "swap!") "'s " (code "tmp") " is renamed away from the "
              "one you already had.")
           (p "This is how the reactive templates, the GLSL forms and the "
              "page you're reading are built: " (b "short declarations in, "
              "correct implementations out") "."))
         macro-code)
      ,(show "06" "Control flow" "call/cc on Wasm's own exceptions"
         '("Escape continuations ride the Wasm exception-handling proposal: "
           "capture is O(1), the normal path costs one try block, and "
           (code "dynamic-wind") " winders unwind inner-to-outer.")
         #t
         '((h3 "Tail calls are return_call")
           (p "Every tail call compiles to the engine's own "
              (code "return_call") " — variadic procedures and "
              (code "apply") " included — so a hundred-million-iteration "
              "loop runs in " (b "constant stack") ", in about 150 ms.")
           (p "No trampolines, no CPS transform, no stack simulation in "
              "JavaScript. The engine does it."))
         contk-code))

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
