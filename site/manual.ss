;; manual.html — authored in Scheme, rendered to HTML by Goeteia.
;; The body is a container; manual.js fills it from docs/manual.md.
(import (web html) (chrome))

(define body
  (list
   `(article (@ (id "doc") (class "doc"))
      (div (@ (class "status")) "loading the manual…"))))

(define scripts
  (list
   `(script (@ (src "https://cdn.jsdelivr.net/npm/marked@12/marked.min.js")))
   `(script (@ (src "manual.js")))))

(write-file "manual.html"
  (render-page "Manual — Goeteia"
               (string-append "The Goeteia developer manual: toolchain and "
                              "self-hosting fixpoint, the library system, the numeric "
                              "tower, call/cc, and the reactive web stack -- rendered "
                              "in your browser from Markdown.")
               (read-file "site/manual.css")
               'manual "site/manual.ss" body
               scripts))
