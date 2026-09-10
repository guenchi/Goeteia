;; expect: 3
;; RED ON PURPOSE: a user's `null?` makes the prelude's `length` loop.
;; The prelude and the user's program are spliced into one flat top
;; level, and the prelude calls primitives by the same bare symbols the
;; user can define.  How many places that is, as a command rather than
;; a number, because a count written into a comment has no author and
;; goes quietly wrong -- two readers measured this file today and got
;; three different answers, all of them honest:
;;
;;     grep -c '(car ' src/prelude.ss      lines, not occurrences
;;     grep -o '(car ' src/prelude.ss | wc -l    occurrences
;;
;; On 2026-09-10 the first answers 103 for `(car ' and 67 for
;; `(null? '.  The point is not the number: it is that every one of
;; them stops meaning what the caller wrote.
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
;; Today this does not print at all -- length's loop never sees the
;; end of the list and the run dies with `illegal cast`.  A trap,
;; not a wrong answer, so it is in a file of its own: it would take
;; any cell after it with it.
(import (rnrs))
(define (null? x) #f)
(display (length (list 1 2 3)))
