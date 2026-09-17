;; expect: #t
(import (rnrs) (gfx mat) (gfx obstacles))
(define (check name value) (unless value (error 'obstacle-identity-test name)))
(define (fails? thunk) (guard (e (else #t)) (thunk) #f))
;; These different names collide in the bounded multiply-by-31 hash.
(define a (obstacle-capsule "shape/ab" 'surface-a 0 0 0.3 0.3 3.7))
(define b (obstacle-capsule "shape/bC" 'surface-b 4 0 0.3 0.3 3.7))
(define world (make-obstacle-index (list a b) 4))
(check "Hash collisions retain both identities"
  (and (eq? (vector-ref (obstacle-sweep world '#(-1 1 0) '#(1 1 0) 0.1) 3) a)
       (eq? (vector-ref (obstacle-sweep world '#(3 1 0) '#(5 1 0) 0.1) 3) b)))
(check "Duplicate text is rejected even in a different string object"
  (fails? (lambda () (make-obstacle-index (list a (obstacle-capsule (string-append "shape/" "ab") 'surface-b 8 0 0.3 0.3 3.7)) 4))))
(define first (obstacle-box "a" 'surface-a 0 1 0 0.2 2 2 0))
(define second (obstacle-box "b" 'surface-b 0 1 0 0.2 2 2 0))
(for-each (lambda (objects)
  (check "Equal-time contact uses stable identity order"
    (eq? (vector-ref (obstacle-sweep (make-obstacle-index objects 4) '#(-2 1 0) '#(2 1 0) 0.1) 3) first)))
  (list (list first second) (list second first)))
(check "Invalid identity is explicit" (fails? (lambda () (obstacle-box #f 'surface-a 0 1 0 1 1 1 0))))
(check "Empty identity is explicit" (fails? (lambda () (obstacle-box "" 'surface-a 0 1 0 1 1 1 0))))
(check "Invalid metadata is explicit" (fails? (lambda () (obstacle-box "a" #f 0 1 0 1 1 1 0))))
(check "Invalid dimensions are explicit" (fails? (lambda () (obstacle-box "a" 'surface-a 0 1 0 0 1 1 0))))
(check "Inverted capsule endpoints are explicit" (fails? (lambda () (obstacle-capsule "a" 'surface-a 0 0 1 2 1))))
(check "Zero cell size is explicit" (fails? (lambda () (make-obstacle-index (list a) 0))))
(check "NaN coordinate is explicit" (fails? (lambda () (obstacle-capsule "a" 'surface-a +nan.0 0 1 0 2))))
(check "Infinity coordinate is explicit" (fails? (lambda () (obstacle-box "a" 'surface-a +inf.0 1 0 1 1 1 0))))
(check "Malformed query point is explicit" (fails? (lambda () (obstacle-sweep world '#(0 1) '#(0 1 2) 1))))
(check "Negative query radius is explicit" (fails? (lambda () (obstacle-sweep world '#(0 1 0) '#(0 1 2) -1))))
(check "Non-finite query point is explicit" (fails? (lambda () (obstacle-sweep world '#(+inf.0 1 0) '#(0 1 2) 1))))
#t
