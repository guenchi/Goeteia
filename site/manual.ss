;; manual.html — authored in Scheme, rendered to HTML by Goeteia.
;; The body is a container; manual.js fills it from docs/manual.md.
(import (web html) (web css) (chrome))

(define body
  (list
   `(div (@ (class "lang"))
      (a (@ (href "manual.html") (data-lang "en")) "EN")
      " · "
      (a (@ (href "manual.html?lang=zh-cn") (data-lang "zh-cn")) "中文"))
   `(article (@ (id "doc") (class "doc"))
      (div (@ (class "status")) "loading the manual…"))))

(define scripts
  (list
   `(script (@ (src "https://cdn.jsdelivr.net/npm/marked@12/marked.min.js")))
   `(script (@ (src "manual.js")))))

;; the rendered-markdown styles, in (web css); soft-box + inline-code
;; come from chrome, shared with the other pages' code blocks.
(define doc-styles
  `((.doc (padding (em 3) 0 (em 4)))
    (".doc h1, .doc h2, .doc h3, .doc h4"
     (font-weight 650) (line-height (dec 1 25)) (margin (em 1 60) 0 (em 0 60)))
    (".doc h1" (font-size (em 2 40)) (margin-top (em 0 20))
     (background "linear-gradient(120deg, var(--lapis), var(--azure))")
     (-webkit-background-clip text) (background-clip text) (color transparent))
    (".doc h2" (font-size (em 1 60)) (padding-bottom (em 0 25))
     (border-bottom (px 1) solid (var line)))
    (".doc h3" (font-size (em 1 25)))
    (".doc h4" (font-size (em 1 5)) (color (var dim)))
    (".doc p, .doc li" (color (var ink)))
    (".doc a" (color (var lapis)))
    (".doc ul, .doc ol" (padding-left (em 1 40)))
    (".doc li" (margin (em 0 25) 0))
    (".doc code" ,@(inline-code) (font-size (em 0 90))
     (background "#eef1f9") (padding (em 0 12) (em 0 40)) (border-radius (px 5)))
    (".doc pre" ,@(soft-box) (padding (em 0 90) (em 1)) (overflow-x auto)
     (font-family (var mono)) (font-size (px 13 50)) (line-height (dec 1 5)))
    (".doc pre code" (color (var ink)) (background none) (padding 0) (font-size inherit))
    (".doc blockquote" (margin (em 1) 0) (padding (em 0 20) (em 1)) (color (var dim))
     (border-left (px 3) solid (var azure)) (background (var bg2))
     (border-radius 0 (px 8) (px 8) 0))
    (".doc hr" (border none) (border-top (px 1) solid (var line)) (margin (em 2) 0))
    (".doc table" (border-collapse collapse) (width (pct 100)) (margin (em 1 20) 0)
     (font-size (em 0 95)))
    (".doc th, .doc td" (border (px 1) solid (var line)) (padding (em 0 50) (em 0 80))
     (text-align left))
    (".doc th" (background (var bg2)) (font-weight 600))
    (".doc img" (max-width (pct 100)))
    (".doc :target" (scroll-margin-top (em 4 50)))
    (.status (padding (em 4) 0) (text-align center) (color (var dim)))
    (".status code" (font-family (var mono)))
    (.lang (text-align right) (font-size (em 0 85)) (margin-top (em 1 20)))
    (".lang a" (color (var dim)))
    (".lang a.active" (color (var lapis)) (font-weight 600))))

(write-file "manual.html"
  (render-page "Manual — Goeteia"
               (string-append "The Goeteia developer manual: toolchain and "
                              "self-hosting fixpoint, the library system, the numeric "
                              "tower, call/cc, and the reactive web stack -- rendered "
                              "in your browser from Markdown.")
               (string-append (css->string (base-styles 52))
                              (css->string doc-styles)
                              (css->string (footer-styles)))
               'manual "site/manual.ss" body
               scripts))
