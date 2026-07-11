;; A DOM counter -- a web page scripted in Goeteia.
(import (web dom) (web js))

(define n 0)
(define label (get-element-by-id "count"))

(define (update!)
  (set-text! label (number->string n)))

(add-event-listener! (get-element-by-id "inc") "click"
  (lambda _ (set! n (+ n 1)) (update!)))
(add-event-listener! (get-element-by-id "dec") "click"
  (lambda _ (set! n (- n 1)) (update!)))
(add-event-listener! (get-element-by-id "reset") "click"
  (lambda _ (set! n 0) (update!)))

(console-log "counter wired from Goeteia")
(update!)
