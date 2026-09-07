;; expect: #t
;; A variadic primitive used as a VALUE must accept as many arguments
;; as the primitive itself.  `+' called directly takes any number of
;; arguments, but the eta-expansion both targets synthesise for `+' as
;; a value is fixed at two, so `(apply + (list 1 2 3))' answered 3 and
;; `((let ((f +)) f) 1 2 3)' silently dropped an argument instead of
;; raising.  Chez answers 6.  Each shape is pinned separately: a wrong
;; answer with no error is the worst of the three outcomes.
(import (rnrs))
(define (through f . args) (f 1 2 3 4))
(and (= (apply + (list 1 2 3)) 6)
     (= (let ((f +)) (f 1 2 3)) 6)
     (= (through +) 10)
     (= (through *) 24)
     (equal? (map + (list 1 2) (list 10 20) (list 100 200)) (list 111 222))
     (equal? (apply list (list 1 2 3 4 5)) (list 1 2 3 4 5))
     (equal? (apply append (list (list 1) (list 2) (list 3))) (list 1 2 3))
     (= (apply max (list 3 4 1 9)) 9)                 ; the answer is past the first two
     (equal? (apply string-append (list "a" "b" "c")) "abc")
     (= (apply min (list 5 4 7 2 8)) 2)
     (= (max 1 5 2) 5)                             ; and the direct call, n-ary too
     (= (apply + (list)) 0)                        ; the identities
     (= (apply * (list)) 1)
     (equal? (list (apply + (list)) (apply * (list))) (list 0 1))   ; boxed: they print, they compare
     (equal? (list (+) (*) (+ 5) (* 7)) (list 0 1 5 7))              ; the direct call agrees
     (equal? (list (+) (*)) (list (apply + (list)) (apply * (list))))  ; with the value form
     (let ((f -)) (= (f 10) -10)))                 ; one argument is also a valid count
