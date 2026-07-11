;; why.html — authored in Scheme, rendered to HTML by Goeteia.
(import (web html) (web css) (chrome))

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
     (div (@ (class "layer"))
       (span (@ (class "n")) "1")
       (div (h2 "Homoiconicity is the ideal substrate for generation")
            (div (@ (class "sub")) "Code is data — generating it " (em "is") " parsing it.")))
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
     (div (@ (class "layer"))
       (span (@ (class "n")) "2")
       (div (h2 "The generate–verify loop is the real win")
            (div (@ (class "sub")) "Untrusted output, made trustworthy by a cheap, automatic oracle.")))
     (div (@ (class "layer-body"))
       (p "This is the part that's genuinely specific to AI. Generated code is "
          "not to be believed; it has to be " (em "proven") ". Scheme makes the proof "
          "cheap and automatic.")
       (ul (@ (class "points"))
         (li (b "Differential testing as the acceptance test.") " One harness "
             "drives the original and the port through identical inputs and compares "
             "outputs. The model never " (em "claims") " correctness — it is forced to "
             "demonstrate it. (That's the web-porter contract.)")
         (li (b "The self-hosting fixpoint as bedrock.") " The compiler recompiles "
             "itself and " (code "stage1 == stage2") " must hold byte-for-byte, on "
             "every change. An oracle that automatically rejects a wrong edit is worth "
             "more than any amount of \"well-written.\"")
         (li (b "read/write round-trip is a free property test.") " For any value, "
             (code "(equal? x (read (open-input-string (write" ,(raw "&#8209;") ">string x))))")
             " is a correctness check the model gets for nothing."))))

   `(section
     (div (@ (class "layer"))
       (span (@ (class "n")) "3")
       (div (h2 "In networking, make the protocol verifiable data")
            (div (@ (class "sub")) "The bugs a model ships are protocol bugs — move them earlier.")))
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
             (a (@ (href "https://igropyr.com")) "Igropyr") ", a high-performance network "
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
(define page-css
  (string-append (css->string (base-styles 52))
                 (read-file "site/why.css")
                 (css->string (footer-styles))))

(write-file "why.html"
  (render-page "Why Scheme? — Goeteia"
               (string-append "Why Scheme is the optimal substrate for AI-generated code: "
                              "homoiconicity makes generation and verification cheap, protocols "
                              "become verifiable data, and a generate–verify loop forces correctness "
                              "instead of assuming it.")
               page-css
               'why "site/why.ss" body))
