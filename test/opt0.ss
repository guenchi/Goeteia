;; expect: (3628800 2.5 55)
;; (%opt 0) -- script mode: inlining, flonum function specialization
;; and named-let loop lowering stand down; results must not change
(%opt 0)
(import (rnrs))
(define (fact n) (if (zero? n) 1 (* n (fact (- n 1)))))
(define (fladd a b) (fl+ a b))          ; would specialize at full opt
(write (list (fact 10)
             (fladd 1.25 1.25)
             (let loop ((i 0) (acc 0))  ; would lower to a wasm loop
               (if (> i 10) acc (loop (+ i 1) (+ acc i))))))
