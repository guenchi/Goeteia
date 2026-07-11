;; expect: #t
(import (web reactive))
(define s (signal 1))
(define t (signal 10))
(define log '())
(define runs 0)
(define e
  (effect (lambda ()
            (set! runs (+ runs 1))
            (set! log (cons (+ (signal-ref s) (signal-ref t)) log)))))
(signal-set! s 2)
(signal-set! t 20)
;; batching coalesces
(batch (lambda ()
         (signal-set! s 3)
         (signal-set! t 30)))
;; same-value writes don't fire
(signal-set! s 3)
;; untracked reads add no deps
(define quiet 0)
(effect (lambda ()
          (set! quiet (+ quiet 1))
          (untracked (lambda () (signal-ref s)))))
(signal-set! s 4)
;; dispose stops reruns
(dispose-effect! e)
(signal-set! t 100)
;; ownership: an effect created inside an effect dies when the outer
;; one reruns, so stale inner effects never fire
(define inner-runs 0)
(define o (signal 0))
(define i (signal 0))
(effect (lambda ()
          (signal-ref o)
          (effect (lambda ()
                    (signal-ref i)
                    (set! inner-runs (+ inner-runs 1))))))
(signal-set! i 1)                       ; inner reruns        -> 2
(signal-set! o 1)                       ; fresh inner         -> 3
(signal-set! i 2)                       ; only the fresh one  -> 4
(and (equal? (reverse log) '(11 12 22 33 34))
     (= runs 5)
     (= quiet 1)
     (= (signal-ref t) 100)
     (begin (signal-update! t (lambda (v) (+ v 1)))
            (= (signal-ref t) 101))
     (= inner-runs 4))
