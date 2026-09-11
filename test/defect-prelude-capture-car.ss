;; expect: (a . 1)
;; REGRESSION GUARD (written as a red witness at 5471f1b; green since).
;; The defect as it then was: a user's `car` is called by the prelude's
;; `assq`. The prelude and the user's program are spliced into one flat
;; top level, and the prelude calls primitives by the same bare symbols
;; the user can define. How many places that is, as a command rather
;; than a number, because a count written into a comment has no author
;; and goes quietly wrong -- two readers measured this file today and
;; got three different answers, all of them honest:
;;
;;     grep -c  '(car ' src/prelude.ss           LINES containing one
;;     grep -o  '(car ' src/prelude.ss | wc -l    OCCURRENCES
;;
;; On 2026-09-10 those answer 103 and 115 for `(car ', and 67 and 67
;; for `(null? '.  Both numbers are quoted because the pair is the
;; point: `(null? ' agrees with itself only because it happens to
;; occur at most once per line, so a line count that HAPPENS to be
;; right teaches nothing about the one that does not.
;;
;; And the quantity a reader wants is occurrences, not lines.  The
;; point is not the number either way: it is that every one of them
;; stops meaning what the caller wrote.
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
(import (except (rnrs) car))
(define (car x) 99)
(display (assq 'a (list (cons 'a 1))))
