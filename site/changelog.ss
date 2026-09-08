;; changelog.html — authored in Scheme, rendered to HTML by Goeteia.
;; The body is a container; changelog.js fills it from docs/CHANGELOG.md.
;; Same shape as site/manual.ss: the two documents are one kind of page.
(import (web html) (web css) (chrome))

(define body
  (list
   `(article (@ (id "doc") (class "doc"))
      (div (@ (class "status")) "loading the changelog…"))))

(define scripts
  (list
   `(script (@ (src "https://cdn.jsdelivr.net/npm/marked@12/marked.min.js")))
   `(script (@ (src "changelog.js")))))

(write-file "changelog.html"
  (render-page "Changelog — Goeteia"
               (string-append "Every published version of Goeteia, newest "
                              "first: the API changes, the bug fixes and what "
                              "each release added. Version numbers come from "
                              "the npm registry, which is the record of what "
                              "shipped.")
               (string-append (css->string (base-styles 52))
                              (css->string (doc-styles))
                              (css->string (footer-styles)))
               'changelog "site/changelog.ss" body
               scripts))
