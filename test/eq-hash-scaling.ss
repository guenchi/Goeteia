;; expect: #t
;; An eq-hashtable must not turn quadratic when its keys are objects.
;;
;; Every key that is not an immediate value hashed to the same bucket, so
;; filling one degenerated into a linear scan and the whole fill into a
;; quadratic one.  Measured before the fix: with vector keys, doubling
;; the count multiplied the time by 3.8 -- quadratic predicts 4, linear
;; predicts 2 -- while fixnum keys stayed flat, which is the control
;; that says the bucket growth itself was working and the hash was not.
;;
;; This is a timing test, so it is written to be dull rather than tight:
;; both measurements come from one process, the counts are large enough
;; that startup does not show, and the threshold sits halfway between
;; the two predictions.  A ratio near 2 passes, one near 4 fails, and
;; nothing in between is claimed.
;;
;; Pairs are deliberately not measured here.  They remain linear,
;; because this runtime offers no identity a hash could be built from,
;; and docs/limits.md says so.  A cell asserting otherwise would be
;; asserting a fix nobody made.
(import (rnrs) (web js))

(define (now)
  (js->number (js-method (js-get (js-global) "Date") "now")))

(define (fill! n keyf)
  (let ((h (make-eq-hashtable)))
    (let loop ((i 0))
      (when (< i n)
        (hashtable-set! h (keyf i) i)
        (loop (+ i 1))))
    (hashtable-size h)))

;; The count is raised until the smaller fill takes long enough to
;; measure.  Without that the control is a lie: fixnum keys finish in
;; under a millisecond, both timings read zero, and the ratio comes out
;; 0.0 -- a number that passes any threshold and means nothing.  A
;; timing test whose base case is unmeasurable is not testing anything.
(define $floor-ms 25.0)
(define $ceiling-n 400000)

(define (time-fill! n keyf)
  (let ((t0 (now)))
    (fill! n keyf)
    (- (now) t0)))

(define (ratio name keyf)
  (fill! 1000 keyf)                             ; warm the code paths
  (let grow ((n 10000))
    (let ((small (time-fill! n keyf)))
      (cond
       ((and (< small $floor-ms) (< n $ceiling-n)) (grow (* 2 n)))
       ((< small $floor-ms)
        (display "  the base case is still under ")
        (display $floor-ms)
        (display " ms at the largest count: this measurement means nothing")
        (newline)
        -1.0)
       (else (/ (time-fill! (* 2 n) keyf) small))))))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))

;; There is deliberately no acceptance cell for vector, string or record
;; keys, and the reason is worth more than a cell would be.
;;
;; A vector's length is fixed for the life of the object, so hashing by
;; it cannot break eq? semantics -- that was checked, and it is true,
;; and it is not the question.  The question is whether it SEPARATES
;; anything, and in practice it does not: vectors used as keys are
;; almost always the same shape as each other (coordinates, colours,
;; fixed-field records), so they land in one bucket anyway.  Measured:
;; twenty thousand vectors all of length 1 take 0.68 s, the same twenty
;; thousand with lengths spread over 200 values take 0.04 s.
;;
;; Writing the cell with varied lengths would turn green and would be a
;; lie -- it would be measuring a shape the field does not produce.  The
;; same holds for strings by length and for records by type.  So the
;; honest record of it is docs/limits.md, not a passing test here.
;;
;; Soundness was verified and usefulness was not; those are two
;; questions, and only the second one decides whether a fix is a fix.

;; bignums: eqv? on numbers is by value, so the value is the hash
(define bignum-ratio (ratio 'bignum (lambda (i) (* 999999 (+ i 1000003)))))
(check "large integer keys scale linearly, not quadratically"
       (and (> bignum-ratio 0.0) (< bignum-ratio 3.0)))

;; the control: this one was never broken, and if it ever fails the
;; measurement is telling us about the machine rather than the hash
(define fixnum-ratio (ratio 'fixnum (lambda (i) i)))
(check "fixnum keys were and remain linear"
       (and (> fixnum-ratio 0.0) (< fixnum-ratio 3.0)))

(unless (= failed 0)
  (display "  ratios: bignum ") (display bignum-ratio)
  (display " fixnum ") (display fixnum-ratio) (newline))
(display (= failed 0))
(newline)
