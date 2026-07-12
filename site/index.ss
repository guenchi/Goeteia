;; index.html — the homepage shell, authored in Scheme, rendered by
;; Goeteia. The hero inside #live is compiled and mounted live in the
;; browser from hero.ss (see index.js); everything else is static.
(import (web html) (web css) (chrome))   ; card / section* come from chrome

(define body
  (list
   `(div (@ (class "cols"))
      (div (@ (id "live")))                 ; the hero mounts here
      (section (@ (id "editor"))
        (p (@ (class "lead"))
           (b "Everything beside this is rendered by Goeteia.") (br)
           "The Scheme below is compiled to WebAssembly " (em "in your browser")
           " and mounted live.")
        (div (@ (class "code"))
          (pre (@ (class "hl") (id "hl") (aria-hidden "true")))
          (textarea (@ (id "src") (rows "22") (spellcheck "false")
                       (autocapitalize "off") (autocorrect "off")) "loading…"))
        (div (@ (class "bar"))
          (button (@ (id "run") (disabled #t)) "Run")
          (span (@ (id "status") (class "status")) "booting the compiler…"))
        (p (@ (class "hint"))
           "No server compiles this — the page carries the whole compiler ("
           (code "goeteia.wasm") ", ~70 KB gzipped, cached after first load), "
           "and each Run recompiles the source above in ~15 ms.")))

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
        ,(card "The numeric tower"
           "Fixnums promote to bignums on overflow (checked inline, two "
           "bit-compares), flonums have contagion, rationals and complex "
           "are exact, and float literals are encoded to IEEE-754 by pure "
           "Scheme — so both hosts emit identical bytes.")
        ,(card "call/cc & dynamic-wind"
           "Escape continuations ride the Wasm exception-handling "
           "proposal: capture is O(1), the normal path costs one try "
           "block, and winders unwind inner-to-outer on the way out.")
        ,(card "A reactive web stack"
           '(code "(web sx)") " templates over fine-grained "
           '(code "(web reactive)") " signals, an " '(code "(web html)")
           " renderer, and a " '(code "(web js)") " FFI that reaches straight "
           "into the host — this page is built with it.")
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
                 "@import url('https://fonts.googleapis.com/css2?family=Metal+Mania&display=swap');\n"
                 (css->string (base-styles 60))
                 (read-file "site/index.css")
                 (css->string (footer-styles)))
               'index "site/index.ss" body
               (list '(script (@ (type "module") (src "index.js"))))))
