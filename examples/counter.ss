;; A DOM counter -- a web page scripted in Goeteia, sx edition.
;; The whole UI is one template: unquotes are reactive holes.
(import (web reactive) (web sx) (web dom))

(define n (signal 0))
(define (bump d) (lambda _ (signal-update! n (lambda (v) (+ v d)))))

(sx-mount (get-element-by-id "app")
  (sx (div
        (div (@ (id "count")) ,(signal-ref n))
        (button (@ (on-click ,(bump -1))) "-")
        (button (@ (on-click ,(lambda _ (signal-set! n 0)))) "0")
        (button (@ (on-click ,(bump 1))) "+"))))

(console-log "counter mounted from Goeteia")
