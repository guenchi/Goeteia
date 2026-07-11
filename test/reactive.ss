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
(and (equal? (reverse log) '(11 12 22 33 34))
     (= runs 5)
     (= quiet 1)
     (= (signal-ref t) 100)
     (begin (signal-update! t (lambda (v) (+ v 1)))
            (= (signal-ref t) 101)))
