;; A site generator with a mount point: running this program prints
;; the complete counter page.  The interactive part sits in a
;; (conjure auto ...) form and compiles to both targets when the
;; page is generated -- the wasm module as a data: URI plus the
;; inline JS fallback, the loader glue riding along, so the output
;; depends on nothing beside itself.  The page itself is (web html)
;; SXML; the section string splices in through `raw`.
;; Regenerate with examples/mk-counter-embedded.sh.
(import (web html))

(display
 (html->document
  `(html
    (head
     (meta (@ (charset "utf-8")))
     (title "Goeteia DOM counter - mount point")
     (style ,(raw "
      body { font-family: system-ui; text-align: center; margin-top: 4em; }
      #count { font-size: 4em; font-weight: 700; margin: .3em; }
      button { font-size: 1.4em; padding: .2em 1em; margin: 0 .3em; }")))
    (body
     (h1 "Goeteia counter")
     (p "This whole page is the output of " (code "counter-page.ss")
        ": the interactive part sits in a " (code "(conjure auto ...)")
        " mount point and was compiled to both targets when the page"
        " was generated.  Append " (code "?goeteia=js")
        " to force the fallback.")
     (div (@ (id "app")))
     ,(raw
       (conjure auto
         (import (web reactive) (web sx) (web dom))
         (define n (signal 0))
         (define (bump d) (lambda _ (signal-update! n (lambda (v) (+ v d)))))
         (sx-mount (get-element-by-id "app")
           (sx (div
                 (div (@ (id "count")) ,(signal-ref n))
                 (button (@ (on-click ,(bump -1))) "-")
                 (button (@ (on-click ,(lambda _ (signal-set! n 0)))) "0")
                 (button (@ (on-click ,(bump 1))) "+"))))
         (console-log "counter conjured from a mount point")))))))
