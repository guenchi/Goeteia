;; expect: #t
;; Variable-level float unboxing: a let binding whose value is
;; statically a flonum lives in a raw f64 local. Reads in float
;; context use the slot directly; generic references box on demand;
;; bindings captured by a lambda or mutated fall back to eqref.
(import (rnrs))

;; the slot, read back in float context
(define basic
  (let ((x (fl* 2.0 3.0)))
    (fl+ x x)))

;; cascading: y's initializer references the f64 slot x
(define cascade
  (let ((x (fl* 2.0 2.0)))
    (let ((y (fl+ x 1.0)))
      (fl* y y))))

;; generic references box: predicates, printing, data structures
(define generic
  (let ((x (fl* 1.0 2.5)))
    (and (flonum? x)
         (equal? (list x x) (list 2.5 2.5))
         (string=? (number->string x) "2.5"))))

;; captured by a lambda: must fall back (closure envs carry eqref)
(define captured
  (let ((x (fl+ 1.0 1.0)))
    ((lambda () (fl* x 3.0)))))

;; mutation: assignment conversion boxes it, no f64 slot
(define mutated
  (let ((x 1.0))
    (set! x (fl+ x 1.0))
    x))

;; f64 slots inside a loop body (the loop variable itself is a lambda
;; parameter and stays eqref; the inner temporaries are unboxed)
(define (norm-sum n)
  (let loop ((i 0) (acc 0.0))
    (if (= i n)
        acc
        (let* ((x (fl* (fixnum->flonum i) 0.5))
               (y (fl+ x 1.0)))
          (loop (+ i 1) (fl+ acc (fl* y y)))))))

;; staging memory in the mix: an f64 slot loaded from memory
(%mem-f64-set! 0 6.25)
(define via-mem
  (let ((x (%mem-f64-ref 0)))
    (flsqrt x)))

(and (fl=? basic 12.0)
     (fl=? cascade 25.0)
     generic
     (fl=? captured 6.0)
     (fl=? mutated 2.0)
     (fl=? (norm-sum 3) (+ 1.0 2.25 4.0))
     (fl=? via-mem 2.5))
