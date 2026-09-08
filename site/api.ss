;; api.html — authored in Scheme, rendered to HTML by Goeteia.
;; The body is a container; api.js fills it from docs/api.md.
;; Same shape as site/manual.ss and site/changelog.ss: a rendered
;; markdown document is one kind of page, and the three share it.
(import (web html) (web css) (chrome))

(define body
  (list
   `(article (@ (id "doc") (class "doc"))
      (div (@ (class "status")) "loading the API index…"))))

(define scripts
  (list
   `(script (@ (src "https://cdn.jsdelivr.net/npm/marked@12/marked.min.js")))
   `(script (@ (src "api.js")))))

(write-file "api.html"
  (render-page "API index — Goeteia"
               (string-append "Every name the libraries export, by library. "
                              "This page explains nothing -- that is what the "
                              "manual is for; it exists so that a name can be "
                              "found at all. It is generated from the export "
                              "forms themselves, so a name that is here is "
                              "exported and a name that is exported is here.")
               (string-append (css->string (base-styles 52))
                              (css->string (doc-styles))
                              (css->string (footer-styles)))
               'api "site/api.ss" body
               scripts))
