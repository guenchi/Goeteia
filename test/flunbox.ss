;; expect: #t
;; Unboxed float expression trees: same semantics as before, no
;; intermediate boxing. Shadowing must fall back to the generic path.
(import (rnrs))

(define fl-tree
  ;; a nested tree: every intermediate stays on the f64 stack
  (fl+ (fl* 2.0 3.0) (fl/ 1.0 4.0)))

(define via-vars
  ;; variables cross the boundary boxed, then unbox once
  (let ((x 2.5)) (fl* x x)))

(define mixed
  (fl+ (fixnum->flonum 1) 0.5))

(define rooted
  (flsqrt (fl+ (fl* 3.0 3.0) (fl* 4.0 4.0))))

;; predicates in the f64 context
(define preds
  (and (fl<? (fl* 2.0 2.0) 5.0)
       (fl=? (fl- 1.0 0.25) 0.75)
       (not (fl<? 5.0 (fl* 2.0 2.0)))))

;; truncation of an unboxed tree
(define trunc (= (%fl->fx (fl* 2.0 3.5)) 7))

;; staging memory in the float context: store an unboxed tree, read it
;; back into another tree
(%mem-f64-set! 0 (fl* 1.5 2.0))
(%mem-f32-set! 8 (fl+ 0.25 0.25))
(define mem-ok
  (and (fl=? (fl+ (%mem-f64-ref 0) 1.0) 4.0)
       (fl=? (%mem-f32-ref 8) 0.5)))

;; lexical shadowing: the head is NOT the primitive here, so the
;; direct path must not fire
(define shadowed
  (let ((fl* (lambda (a b) 99.0)))
    (fl=? (fl+ (fl* 2.0 3.0) 1.0) 100.0)))

(and (fl=? fl-tree 6.25)
     (fl=? via-vars 6.25)
     (fl=? mixed 1.5)
     (fl=? rooted 5.0)
     preds trunc mem-ok shadowed)
