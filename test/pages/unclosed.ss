;; The (define ...) below is never closed.
(import (rnrs) (web dom))
(define (greet who)
  (let ((n (create-element "p")))
    (set-text! n who)
    (append-child! (get-element-by-id "app") n)
(greet "hello")
