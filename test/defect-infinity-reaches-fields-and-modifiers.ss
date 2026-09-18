;; expect: #t
;; EXPECTED FAIL against lib/gam/fields.ss and lib/gam/modifiers.ss.
;; The NaN sweep closed NaN.  It did not close the infinities, and in
;; two of the libraries they reach the state.
;;
;; THE SHARPEST ROW IS NOT A DIRTY NUMBER, IT IS AN INVERTED ANSWER.
;; field-contains? tests (not (< (* r r) (+ (* over over) (* across across)))).
;; With an infinite coordinate the sum is infinite, the comparison is
;; TRUE, and so the answer is #f -- but with an infinite coordinate in
;; the other position, or where a subtraction of two infinities makes
;; the sum NaN, every comparison is FALSE and `not` turns that into #t:
;; a point infinitely far away is reported as INSIDE a circle of radius
;; five.  Measured below.
;;
;; That is the same mechanism as the NaN cooldown and the NaN pool: a
;; comparison that answers false, sitting behind `not`, is a door that
;; is always open.  The value being wrong is the small half; the
;; predicate being wrong is the large one.
;;
;; WHY THIS IS SEPARATE FROM THE NaN BATCH.  (= x x) excludes NaN only,
;; which is what that batch ruled and what it says it did.  Excluding
;; the infinities is a different test -- the tree already has one, twice:
;; $finite? at lib/sim/step.ss:69 and fl-finite? at lib/web/frac.ss:92,
;; both (fl=? 0.0 (fl- v v)) -- and whether each site should use it is a
;; question with a different answer per library.  stats does not need it:
;; measured, $clamp holds an infinite set to the pool's max or zero,
;; because (< max +inf.0) is true.  fields and modifiers do.
(import (rnrs) (gam fields) (gam modifiers))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (try thunk) (guard (e (#t 'refused)) (thunk) 'accepted))
(define (finite? x) (and (real? x) (= x x) (< -1e308 x) (< x 1e308)))

;; ---- fields: the predicate, which is the part that matters
(define f (make-field 'circle 0.0 0.0 5.0 0.0 0.0 2.0 1.0 0.5))
(want "a point infinitely far away is not inside a circle of radius five"
      (field-contains? f +inf.0 0.0) #f)
(want "nor is it on the other axis" (field-contains? f 0.0 +inf.0) #f)
(want "nor infinitely far the other way" (field-contains? f -inf.0 0.0) #f)
;; CONTROL: the predicate still answers ordinary positions, so a repair
;; that refused every position would not pass by being strict.
(want "the centre is inside" (field-contains? f 0.0 0.0) #t)
(want "a point beyond the radius is outside" (field-contains? f 99.0 0.0) #f)

;; ---- fields: the constructor
(want "make-field refuses an infinite x"
      (try (lambda () (make-field 'circle +inf.0 0.0 5.0 0.0 0.0 2.0 1.0 0.5))) 'refused)
(want "make-field refuses an infinite radius"
      (try (lambda () (make-field 'circle 0.0 0.0 +inf.0 0.0 0.0 2.0 1.0 0.5))) 'refused)
(want "make-field still accepts ordinary numbers"
      (try (lambda () (make-field 'circle 1.0 2.0 5.0 0.0 0.5 2.0 1.0 0.5))) 'accepted)

;; ---- modifiers: an infinite value is stored and read back
(let ((m (make-modifiers)))
  (want "modifier-set! refuses an infinite value"
        (try (lambda () (modifier-set! m 'buff 'atk +inf.0 2.0 #f #t))) 'refused)
  (want "and nothing infinite can be read back" (finite? (modifier-ref m 'atk)) #t))
;; CONTROL: a negative modifier is the reason there was no ordering test
;; here in the first place, so it must still work.
(let ((m (make-modifiers)))
  (modifier-set! m 'debuff 'atk -3 2.0 #f #t)
  (want "a debuff still applies" (modifier-ref m 'atk) -3))

;; ---- stats is NOT in this cell, and the measurement says why: the
;; ---- clamp already holds an infinite set to the pool's bounds.
(if (null? fails) #t fails)
