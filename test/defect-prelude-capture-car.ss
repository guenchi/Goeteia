;; expect: (a . 1)
;; RED ON PURPOSE: a user's `car` is called by the prelude's `assq`.
;; The prelude and the user's program are spliced into one flat top
;; level, and the prelude calls primitives by the same bare symbols the
;; user can define.  src/prelude.ss contains 101 uses of `(car ` and 65
;; of `(null? `.  -> Defining one of those names at top level does not
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
;; unfixed, since it is the spelling that already dispatches.  -> Fixing
;; C02's eleven guards without this would turn two working programs into
;; broken ones.  See test/prelude-capture-value-form.ss, which pins
;; those two and must stay green.
;;
;; Today this prints #f: assq walked the list with the user's car,
;; which answers 99 for everything, so nothing matched.
(import (rnrs))
(define (car x) 99)
(display (assq 'a (list (cons 'a 1))))
