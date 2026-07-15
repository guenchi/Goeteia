;; agent.html — authored in Scheme, rendered to HTML by Goeteia.
(import (web html) (web css) (chrome))

(define body
  (list
   `(header
     (h1 "Agents")
     (p (@ (class "tagline")) "Agents that carry code " (em "into") " Goeteia —"
        " each one leaves proof, not promises."))

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
    (".feat"
     (border (px 1) solid (var line)) (border-radius (px 10)) (padding (em 0 90) (em 1))
     (background (var bg)))
    (".feat h4" (margin 0 0 (em 0 30)) (font-size (em 0 95)) (color (var lapis)))
    (".feat p" (margin 0) (color (var dim)) (font-size (em 0 90)))
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
               (string-append "Agents for Goeteia. web-porter rewrites a "
                              "JavaScript/TypeScript web file into Goeteia Scheme with "
                              "behavioral equivalence proved by differential testing — "
                              "download the agent definition.")
               (string-append (css->string (base-styles 52))
                              (css->string agent-styles)
                              (css->string (footer-styles)))
               'agent "site/agent.ss" body))
