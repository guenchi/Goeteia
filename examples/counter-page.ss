;; A site generator with a mount point: running this program prints
;; the complete counter page, the interactive part compiled right
;; here by (goeteia-embed auto ...) -- the wasm module as a data: URI
;; plus the inline JS fallback, picked by engine support at load
;; time.  Regenerate with examples/mk-counter-embedded.sh.
(display "<!DOCTYPE html>\n<html>\n  <head>\n    <meta charset=\"utf-8\">\n")
(display "    <title>Goeteia DOM counter &#8212; mount point</title>\n")
(display "    <style>\n")
(display "      body { font-family: system-ui; text-align: center; margin-top: 4em; }\n")
(display "      #count { font-size: 4em; font-weight: 700; margin: .3em; }\n")
(display "      button { font-size: 1.4em; padding: .2em 1em; margin: 0 .3em; }\n")
(display "    </style>\n  </head>\n  <body>\n")
(display "    <h1>Goeteia counter</h1>\n")
(display "    <p>This whole page is the output of <code>counter-page.ss</code>:\n")
(display "    the interactive part sits in a <code>(goeteia-embed auto ...)</code>\n")
(display "    mount point and was compiled to both targets when the page was\n")
(display "    generated.  Append <code>?goeteia=js</code> to force the fallback.</p>\n")
(display "    <div id=\"app\"></div>\n")
(goeteia-page-section)
(display "  </body>\n</html>\n")

(define (goeteia-page-section)
  (display
   (goeteia-embed (auto (rt "../rt/web.mjs"))
     (import (web reactive) (web sx) (web dom))
     (define n (signal 0))
     (define (bump d) (lambda _ (signal-update! n (lambda (v) (+ v d)))))
     (sx-mount (get-element-by-id "app")
       (sx (div
             (div (@ (id "count")) ,(signal-ref n))
             (button (@ (on-click ,(bump -1))) "-")
             (button (@ (on-click ,(lambda _ (signal-set! n 0)))) "0")
             (button (@ (on-click ,(bump 1))) "+"))))
     (console-log "counter mounted from a goeteia-embed mount point"))))
