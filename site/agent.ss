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
         (div (@ (class "feat"))
           (h4 "Equivalence, demonstrated")
           (p "The single acceptance criterion is behavioral equivalence, shown "
              "with a diff harness that runs both sides — never assumed."))
         (div (@ (class "feat"))
           (h4 "Reactive loop")
           (p "Understand → translate → build the oracle → run & compare → repeat, "
              "until the harness reports full equivalence."))
         (div (@ (class "feat"))
           (h4 "Idiomatic mapping")
           (p (code "useState") "→" (code "signal") ", " (code "useEffect") "→"
              (code "effect") ", JSX→" (code "(web sx)") " — not a transliteration."))
         (div (@ (class "feat"))
           (h4 "Honest residue")
           (p "Delivers the port, the runnable harness, and a report of exactly what "
              "diverges and what needs a human decision.")))

       (div (@ (class "meta"))
         "tools: " (code "Bash, Read, Write, Edit, Grep, Glob"))))))

(write-file "agent.html"
  (render-page "Agents — Goeteia"
               (string-append "Agents for Goeteia. web-porter rewrites a "
                              "JavaScript/TypeScript web file into Goeteia Scheme with "
                              "behavioral equivalence proved by differential testing — "
                              "download the agent definition.")
               (string-append (css->string (base-styles 60))
                              (read-file "site/agent.css")
                              (css->string (footer-styles)))
               'agent "site/agent.ss" body))
