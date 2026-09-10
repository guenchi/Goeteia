;; expect: #t
;; The two spellings of the same program that WORK -- and the reason
;; they work is about to be removed.
;; The prelude and the user's program are spliced into one flat top
;; level, and the prelude calls primitives by the same bare symbols the
;; user can define.  src/prelude.ss contains 101 uses of `(car ` and 65
;; of `(null? `.  Defining one of those names at top level does not
;; capture five synthesised calls -- it captures that name everywhere in
;; the prelude that survives dead-code elimination.
;;
;; Which programs break is program-dependent, and that is WORSE than
;; universal, not better: it appears only when the user's program
;; happens to reach a prelude procedure that uses the name they defined.
;; `(define (car x) 99)` with a program that only calls `length` is
;; fine, because length uses cdr and null? and not car.
;;
;; And the two spellings do not agree.  `(define (f …) …)` is broken
;; today; `(define f (lambda …))` works -- and works ONLY because C02 is
;; unfixed, since it is the spelling that already dispatches.  Fixing
;; C02's eleven guards without this would turn two working programs into
;; broken ones.  See test/prelude-capture-value-form.ss, which pins
;; those two and must stay green.
;;
;; These are green because the value form `(define f (lambda …))`
;; is the spelling C02's eleven guards already dispatch on, so the
;; prelude's call still reaches the primitive.  Fixing C02 without
;; fixing the capture would make these two fail exactly the way the
;; procedure-form files beside them fail now.
;;
;; So this file is not a passing test to be reassured by.  It is
;; the pair that says a repair went too far, and it is worth more
;; than the two red files: they say the defect exists, and this says
;; what a fix is not allowed to cost.
(import (rnrs))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))

(define car (lambda (x) 99))
(check "a value-form car does not reach the prelude's assq"
       (equal? '(a . 1) (assq 'a (list (cons 'a 1)))))
(define null? (lambda (x) #f))
(check "a value-form null? does not reach the prelude's length"
       (= 3 (length (list 1 2 3))))
(display (= failed 0))
