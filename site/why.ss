;; why.html — authored in Scheme, rendered to HTML by Goeteia.
(import (web html) (web css) (web component) (chrome))

(define body
  (list
   `(header
     (div (@ (class "head-row"))
       (h1 "Why Scheme?")
       (span (@ (class "era")) "in the age of AI" ,(raw "&nbsp;") "programming"))
     (p (@ (class "lede"))
        "Not because it reads elegantly to a human — because a "
        "model can reliably " (em "generate") " it, " (em "verify") " it, and "
        (em "manipulate") " it."))

   `(section
     (p "The bottleneck of AI-written code isn't taste — it's trust. A model "
        "is strongest at producing " (strong "constrained structure") " and "
        "weakest at " (strong "guaranteeing runtime semantics") ". Scheme's "
        "value for AI is that its structure lines up with the first and hands the "
        "second to a machine. That points to an optimum that looks different from "
        "the one you'd pick for a human."))

   `(section
     ,(layer "1" "Homoiconicity is the ideal substrate for generation"
            '("Code is data — generating it " (em "is") " parsing it."))
     (div (@ (class "layer-body"))
       (ul (@ (class "points"))
         (li (b "No text↔AST round-trip.") " An s-expression the model emits is "
             "already a parsed tree. Generation, validation and rewriting all happen "
             "on the same structure — no fragile JS/TS parser standing between intent "
             "and syntax. This is exactly what " (a (@ (href "agent.html")) "web-porter")
             " leans on: the target language is s-expr, so verification and rewrites "
             "work on the tree.")
         (li (b "Structural validity is nearly free.") " JS invites missing "
             "semicolons, mismatched " (code "async") ", a forgotten " (code "await") ". "
             "An s-expr is syntactically valid the moment its parens balance — the "
             "error surface shrinks by an order of magnitude.")
         (li (b "Macros let the model generate at the right altitude.") " It "
             "doesn't hand-roll a codec line by line; it emits one "
             (code "(define-message …)") " declaration and the macro expands it to "
             "correct code. The model writes intent — short, clear, checkable — and "
             "the compiler writes the implementation. That's the division of labour "
             "it's least likely to botch."))))

   `(section
     ,(layer "2" "The generate–verify loop is the real win"
            '("Untrusted output, made trustworthy by a cheap, automatic oracle."))
     (div (@ (class "layer-body"))
       (p "This is the part that's genuinely specific to AI. Generated code is "
          "not to be believed; it has to be " (em "proven") ". Scheme makes the proof "
          "cheap and automatic.")
       (ul (@ (class "points"))
         (li (b "Differential testing as the acceptance test.") " Values serialize "
             "with " (code "write") " and compare with " (code "equal?") ", so one "
             "harness can drive two implementations through identical inputs and check "
             "them against each other exactly. The model never " (em "claims") " "
             "correctness — it is forced to demonstrate it (porting one codebase to "
             "another is just this contract).")
         (li (b "An automatic oracle beats \"well-written.\"") " A check that "
             "mechanically rejects a wrong edit — a fixpoint, an invariant, a golden "
             "comparison — holds on every change with no human in the loop, and is "
             "worth more than any amount of prose polish. (A self-hosting compiler is "
             "the limit case: recompile itself and the output must match "
             "byte-for-byte.)")
         (li (b "read/write round-trip is a free property test.") " For any value, "
             (code "(equal? x (read (open-input-string (write" ,(raw "&#8209;") ">string x))))")
             " is a correctness check the model gets for nothing."))))

   `(section
     ,(layer "3" "The frontend program is data too — the ground Lisp stands on"
            '("The homoiconic advantage doesn't stop at logic; it covers the whole UI."))
     (div (@ (class "layer-body"))
       (p "An HTML document is a tree; a stylesheet is a list of selector-and-"
          "declaration rules — the exact shapes s-expr was made for. So "
          (code "(web html)") " and its dual " (code "(web css)") " are just two pure "
          "functions over one representation, and the UI becomes ordinary program "
          "data: built and checked the same way as the logic beside it.")
       (ul (@ (class "points"))
         (li (b "One language, top to bottom.") " Markup, styles and logic are all "
             "s-expr — no second templating dialect, no string interpolation to get "
             "wrong.")
         (li (b "A colour is a value, not a convention.") " "
             (code "(define lapis \"#1550c4\")") " is one binding shared by CSS and "
             "code — computed, reused, checked once — where a stylesheet would leave "
             "you copying " (code "var(--x)") " strings and hoping they line up.")
         (li (b "Abstraction is just functions and macros.") " A "
             (code "(define (card radius) …)") " factors a family of rules; "
             (code "(media-down 42 …)") " and " (code "(prefixed transform …)")
             " expand the boilerplate. The model writes intent; the expander writes "
             "the correct CSS — the same division of labour as homoiconic codegen, "
             "now for the UI.")
         (li (b "DRY is an ordinary list operation.") " A stylesheet is a list, so "
             (code "(append base-css page-css)") " composes shared chrome with the "
             "page's own rules. No preprocessor, no build DSL — just values."))
       (p "The proof is the page you are on: its markup and every rule in its "
          "stylesheet are " (code "site/why.ss") ", a Scheme program Goeteia compiled "
          "and ran to emit this HTML. The site is built exactly the way the argument "
          "says to build it.")))

   `(section
     ,(layer "4" "In networking, make the protocol verifiable data"
            '("The bugs a model ships are protocol bugs — move them earlier."))
     (div (@ (class "layer-body"))
       (p "The biggest risk in AI-written network code is the protocol: fields "
          "out of order, an encoder that doesn't match its decoder, a state machine "
          "missing a transition — the kind of thing that only detonates at runtime. "
          "Scheme moves it forward in time.")
       (ul (@ (class "points"))
         (li (b "Same language on both ends, s-expr on the wire.") " There is no "
             "protocol to " (em "design") " — the model just " (code "read") "s and "
             (code "write") "s. No protocol, no protocol bug. For the thing a "
             "model is most likely to get wrong, the best move is to delete it.")
         (li (b "Declarative schema for the heterogeneous case.") " Facing a "
             "foreign backend, the model generates a " (code "define-json") " / "
             (code "define-message") " schema rather than a hand-written codec — "
             "and the test checks symmetry directly: " (code "(decode (encode x)) = x") ".")
         (li (b "Not hypothetical — it already ships.") " "
             (a (@ (href "https://igropyr.dev")) "Igropyr") ", a high-performance network "
             "server written in pure Scheme, already accepts s-expression payloads "
             "over the wire. The same-language, no-codec path is production, not a "
             "proposal."))
       (div (@ (class "callout"))
         (span (@ (class "k")) "The optimum, in one line")
         (p "Declarative protocol & schema, plus automatic differential and "
            "round-trip verification. The model emits short, declarative, "
            "structurally-valid " (em "intent") " — schemas, routes, " (code "sx")
            " templates; macros produce the implementation; the machine proves it "
            "correct. Work lands on the model's strength; risk lands on the verifier."))))

   `(section (@ (class "note"))
     (div (@ (class "note-head"))
       (h2 "An honest counterpoint")
       (span (@ (class "note-sub")) "Ecosystem and training data cut the other way"))
     (p "Models have seen orders "
        "of magnitude more JavaScript, so their intuitive recall for it is stronger; "
        "writing Scheme leans harder on the verification scaffolding above to catch "
        "what recall would have caught for free. JavaScript is the language a model "
        "remembers better — but Scheme has the properties that " (em "matter") " for "
        "code that must be verified anyway, provided you actually build the loop. "
        "Here, it's built: differential testing, the self-hosting fixpoint, and "
        "read/write round-trips.")
     (p "And the ecosystem gap is narrower than it looks, because you don't have "
        "to leave the JavaScript world to enter Goeteia. Its " (code "(web js)")
        " FFI bridge reaches straight into the host: a port can call into any "
        "existing JavaScript library — the whole npm-scale ecosystem stays one call "
        "away, seamlessly. You verify the code you write; you borrow, unchanged, the "
        "libraries the world already wrote."))))

;; shared base (palette + nav) from chrome, then this page's own rules,
;; then the shared footer
(define-component (layer n title sub)
  ;; a numbered layer: the badge, heading and subhead carry their css;
  ;; the four layers intern to one class (the body is a sibling block)
  (style
    (display flex) (gap (em 1 10)) (align-items baseline)
    (".n" (flex none) (font-family (var mono)) (font-weight 700) (font-size (em 1 5))
          (color "#fff") (background (var lapis))
          (width (em 1 90)) (height (em 1 90)) (border-radius (pct 50))
          (display inline-flex) (align-items center) (justify-content center))
    ("h2" (font-size (em 1 50)) (font-weight 600) (margin 0))
    (".sub" (color (var dim)) (font-size (em 0 95)) (margin-top (em 0 15))))
  (div
    (span (@ (class "n")) ,n)
    (div (h2 ,title) (div (@ (class "sub")) ,@sub))))

(define why-styles
  `((header (padding (em 5) 0 (em 2 50)))
    (".head-row" (display flex) (align-items baseline) (justify-content flex-start) (gap (em 0 70)) (flex-wrap wrap))
    (h1
     (font-size (em 3)) (margin 0) (font-weight 650) (letter-spacing (em 0 2))
     (background "linear-gradient(120deg, var(--lapis), var(--azure))")
     (-webkit-background-clip text) (background-clip text) (color transparent))
    (".era" (font-family (var mono)) (font-size (em 0 85)) (color (var dim)))
    (".lede" (color (var dim)) (font-size (em 1 20)) (margin-top (em 0 80)) (max-width (em 34)))
    (section (padding (em 2 40) 0) (border-top (px 1) solid (var line)))
    (p (color (var ink)))
    (code (font-family (var mono)) (color (var lapis)) (font-size (em 0 90))
          (background "#eef1f9") (padding (em 0 10) (em 0 38)) (border-radius (px 5)))
    (pre
     (background "#eef1f9") (border (px 1) solid (var line))
     (padding (em 0 90) (em 1)) (border-radius (px 8)) (overflow-x auto)
     (font-family (var mono)) (font-size (px 13 50)) (line-height (dec 1 50)))
    ("pre code" (color (var ink)) (background none) (padding 0))
    ;; numbered layers (the .layer badge/heading are a component now)
    (".layer-body" (margin-left (em 3)))
    ("ul.points" (list-style none) (padding 0) (margin (em 1 10) 0 0))
    ("ul.points > li"
     (position relative) (padding-left (em 1 30)) (margin (em 0 90) 0) (color (var ink)))
    ("ul.points > li::before"
     (content "\"→\"") (position absolute) (left 0) (color (var azure)) (font-weight 700))
    ("ul.points b" (color (var ink)))
    (".callout"
     (margin (em 1 40) 0 0) (padding (em 1 30) (em 1 50))
     (background (var bg2)) (border (px 1) solid (var line))
     (border-left (px 4) solid (var lapis)) (border-radius 0 (px 12) (px 12) 0)
     (box-shadow 0 (px 1) (px 3) (rgba 16 20 42 (dec 0 6))))
    (".callout .k" (color (var lapis)) (font-weight 700) (font-size (em 0 80))
                   (letter-spacing (em 0 8)) (text-transform uppercase))
    (".callout p" (margin (em 0 50) 0 0) (font-size (em 1 8)))
    (".note" (color (var dim)))
    (".note h2" (color (var ink)) (margin 0))
    (".note-head" (margin-bottom (em 0 80)))
    (".note-sub"
     (display block) (text-align center) (margin-top (em 0 30))
     (color (var dim)) (font-size (em 0 95)))))

(define page-css
  (string-append (css->string (base-styles 52))
                 (css->string why-styles)
                 (css->string (styled-css))
                 (css->string (footer-styles))))

(write-file "why.html"
  (render-page "Why Scheme? — Goeteia"
               (string-append "Why Scheme is the optimal substrate for AI-generated code: "
                              "homoiconicity makes generation and verification cheap, protocols "
                              "become verifiable data, and a generate–verify loop forces correctness "
                              "instead of assuming it.")
               page-css
               'why "site/why.ss" body
               ;; the typeset effect: heading glyphs that dodge the
               ;; cursor (why-fx.ss, precompiled to why-fx.wasm)
               (list '(script (@ (type "module") (src "why-fx.js"))))))
