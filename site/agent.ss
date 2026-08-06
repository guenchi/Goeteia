;; agent.html — authored in Scheme, rendered to HTML by Goeteia.
(import (web html) (web css) (web component) (chrome))

(define body
  (list
   `(header
     (h1 "Agents")
     (p (@ (class "tagline")) "Agents that carry code " (em "into") " Goeteia —"
        " each one leaves proof, not promises."))

   `(section
     (h2 "web-builder")
     (p (@ (class "hint") (style "color:var(--dim)"))
        "Describe a page and it builds the whole thing in Goeteia Scheme — "
        "HTML and CSS written by a generator at build time, the interactive "
        "half compiled inside mount points in the same source: wasm, the "
        "generated JS fallback and the loader, with 3D and networking when "
        "the page calls for them. It never hand-writes JavaScript.")

     (div (@ (class "agent"))
       (div (@ (class "agent-head"))
         (div (h3 "web-builder")
              (div (@ (class "role"))
                   "one source" ,(raw "&nbsp;") "→" ,(raw "&nbsp;")
                   "page + wasm + fallback · every behavior smoke-tested"))
         (a (@ (class "btn primary") (href "agent/web-builder.md") (download #t))
            (span (@ (class "ic")) "↓") "Download web-builder.md"))

       (p (@ (class "agent-lead"))
          "The generator " (em "is") " the build: one " (code ".ss")
          " runs at build time, writes the page, and its mount points emit "
          "every artifact the page needs. Engine fallback (no WasmGC) is "
          "generated, never maintained; capability degradation (no WebGL2, "
          "nothing should even be fetched) is written as a Scheme gating "
          "mount that probes, reveals, loads — and rolls back.")

       (div (@ (class "feats"))
         ,(feat "The whole stack, one language"
            '(code "(web html)") " and " '(code "(web css)")
            " as data, " '(code "define-component") " for shared styles, "
            '(code "(web reactive)") " signals for state, "
            '(code "(gfx)") " for WebGL, " '(code "(web rpc)")
            " for datum-on-the-wire networking.")
         ,(feat "Fallback, both questions"
            '(code "define-wasm-js") " automates the engine twin from one "
            "source; degradation gates are their own "
            '(code "define-js") " mounts reaching the published loader handle.")
         ,(feat "Zero hand-written JS"
            "Everything the browser runs is compiled from the same Scheme "
            "tree that generated the page around it.")
         ,(feat "Driven, not asserted"
            "Generator smoke, node-side smoke of every degradation road, and "
            "dual-backend agreement plus absolute value checks — a diff test "
            "alone passes when both sides are wrong the same way."))

       (div (@ (class "meta"))
         "tools: " (code "Bash, Read, Write, Edit, Grep, Glob"))))

   `(section
     (h2 "3d-builder")
     (p (@ (class "hint") (style "color:var(--dim)"))
        "Hand it an asset and it builds the whole 3D pipeline in Goeteia — "
        "glTF in, shader programs composed from the combinators, animation "
        "driven through a state machine, an interactive viewer page out. It "
        "proves what it can with numbers before anyone is asked to look at "
        "pixels.")

     (div (@ (class "agent"))
       (div (@ (class "agent-head"))
         (div (h3 "3d-builder")
              (div (@ (class "role"))
                   "asset" ,(raw "&nbsp;") "→" ,(raw "&nbsp;")
                   "shaded, skinned, animated · verified headlessly first"))
         (a (@ (class "btn primary") (href "agent/3d-builder.md") (download #t))
            (span (@ (class "ic")) "↓") "Download 3d-builder.md"))

       (p (@ (class "agent-lead"))
          "Shaders are s-expressions and the loader's vertex layout is a fixed "
          "contract, so most of a 3D pipeline can be settled before a browser "
          "opens: parse the asset, print the generated GLSL and read it, check "
          "the joint matrices, drive a recording mock GL and inspect the calls "
          "it received. Only what genuinely needs eyes gets handed over.")

       (div (@ (class "feats"))
         ,(feat "The layout is law"
            "One canonical attribute order with fixed widths. "
            '(code "gprim-layout") " names what a primitive carries — that, "
            "not the material, is the contract a program must match.")
         ,(feat "Shaders you can read"
            "Programs compose from combinators and print as GLSL, so a "
            "wrong varying is caught by reading the text, not by staring "
            "at a black canvas.")
         ,(feat "Numbers before pixels"
            "glTF parsing, joint matrices and draw calls all verify "
            "headlessly. A human is asked only for what a machine cannot "
            "judge.")
         ,(feat "Knows its edges"
            "Library gaps go back to the compiler's own review loop rather "
            "than being papered over here, and 2D pages belong to "
            '(code "web-builder") "."))

       (div (@ (class "meta"))
         "tools: " (code "Bash, Read, Write, Edit, Grep, Glob"))))

   `(section
     (h2 "web-porter")
     (p (@ (class "hint") (style "color:var(--dim)"))
        "Point it at one JavaScript or TypeScript web file — a React component, "
        "a DOM script, a piece of pure logic — and it hands back the same thing "
        "rewritten in Goeteia Scheme, together with the differential test that "
        (strong "proves") " the two behave identically. It never claims an "
        "equivalence it did not actually run.")

     (div (@ (class "agent"))
       (div (@ (class "agent-head"))
         (div (h3 "web-porter")
              (div (@ (class "role"))
                   "JS/TS" ,(raw "&nbsp;") "→" ,(raw "&nbsp;")
                   "Goeteia Scheme · verified by differential testing"))
         (a (@ (class "btn primary") (href "agent/web-porter.md") (download #t))
            (span (@ (class "ic")) "↓") "Download web-porter.md"))

       (p (@ (class "agent-lead"))
          "A same-result porter, not a JavaScript-in-Scheme runtime. It ports the "
          "UI subset and the ordinary logic around it into idiomatic Goeteia, then "
          "drives both the original and the port through identical inputs and events "
          "and compares the outputs. Where a pathological JS corner is genuinely "
          "load-bearing, it stops and leaves an honest " (code ";; TODO(port)")
          " with the failing case — rather than emulating all of JavaScript.")

       (div (@ (class "feats"))
         ,(feat "Equivalence, demonstrated"
            "The single acceptance criterion is behavioral equivalence, shown "
            "with a diff harness that runs both sides — never assumed.")
         ,(feat "Reactive loop"
            "Understand → translate → build the oracle → run & compare → repeat, "
            "until the harness reports full equivalence.")
         ,(feat "Idiomatic mapping"
            '(code "useState") "→" '(code "signal") ", " '(code "useEffect") "→"
            '(code "effect") ", JSX→" '(code "(web sx)") " — not a transliteration.")
         ,(feat "Honest residue"
            "Delivers the port, the runnable harness, and a report of exactly what "
            "diverges and what needs a human decision."))

       (div (@ (class "meta"))
         "tools: " (code "Bash, Read, Write, Edit, Grep, Glob"))))))

(define agent-styles
  `((header (padding (em 5) 0 (em 2 50)) (text-align center))
    (h1
     (font-size (em 3)) (margin 0) (font-weight 650) (letter-spacing (em 0 2))
     (background "linear-gradient(120deg, var(--lapis), var(--azure))")
     (-webkit-background-clip text) (background-clip text) (color transparent))
    (".tagline" (color (var dim)) (font-size (em 1 15)) (margin-top (em 0 70)))
    (section (padding (em 2 50) 0) (border-top (px 1) solid (var line)))
    (h2 (font-size (em 1 50)) (font-weight 600))
    (code (font-family (var mono)) (color (var lapis)) (font-size (em 0 92)))
    (pre
     (background "#eef1f9") (border (px 1) solid (var line))
     (padding (em 0 90) (em 1)) (border-radius (px 8))
     (white-space pre-wrap) (font-family (var mono)) (font-size (px 13 50))
     (overflow-x auto))
    ("pre code" (color (var ink)))
    ;; agent card
    (".agent"
     (background (var bg2)) (border (px 1) solid (var line))
     (border-radius (px 14)) (padding (em 1 60) (em 1 60) (em 1 80))
     (box-shadow 0 (px 1) (px 3) (rgba 16 20 42 (dec 0 6)))
     (margin-top (em 1 60)))
    (".agent-head"
     (display flex) (align-items flex-start) (justify-content space-between)
     (gap (em 1)) (flex-wrap wrap))
    (".agent-head h3"
     (margin 0) (font-size (em 1 35)) (font-weight 650)
     (font-family (var mono)) (color (var ink)))
    (".agent-head .role" (color (var dim)) (font-size (em 0 92)) (margin-top (em 0 20)))
    (".agent-lead" (margin (em 1 10) 0 0) (color (var ink)))
    (".meta" (color (var dim)) (font-size (em 0 85)) (margin-top (em 0 80)))
    (".meta code" (color (var dim)))
    (".feats"
     (display grid) (grid-template-columns "repeat(auto-fit, minmax(15em, 1fr))")
     (gap (em 0 90)) (margin (em 1 40) 0 0))
    (".btns" (margin-top (em 1 60)) (display flex) (gap (em 0 70)) (flex-wrap wrap) (align-items center))
    (".btn"
     (display inline-block) (padding (em 0 60) (em 1 50)) (border-radius (px 8))
     (border (px 1) solid (var line)) (color (var ink)) (font-weight 600) (font-size (em 0 95)))
    (".btn:hover" (text-decoration none) (border-color (var lapis)))
    (".btn.primary" (background (var lapis)) (color "#fff") (border-color (var lapis)))
    (".btn.primary:hover" (filter "brightness(1.1)") (border-color (var lapis)))
    (".btn .ic" (margin-right (em 0 45)))
    (".install" (margin-top (em 2 20)))
    (".install h2" (font-size (em 1 15)))))

(write-file "agent.html"
  (render-page "Agents — Goeteia"
               (string-append "Agents for Goeteia. web-builder builds a page from "
                              "scratch — HTML, CSS, wasm, generated JS fallback and "
                              "RPC in one source; 3d-builder takes a glTF asset through "
                              "shading, skinning and animation to a viewer page, "
                              "verified headlessly; web-porter rewrites a "
                              "JavaScript/TypeScript web file into Goeteia Scheme with "
                              "behavioral equivalence proved by differential testing — "
                              "download the agent definitions.")
               (string-append (css->string (base-styles 52))
                              (css->string agent-styles)
                              (css->string (styled-css))
                              (css->string (footer-styles)))
               'agent "site/agent.ss" body))
