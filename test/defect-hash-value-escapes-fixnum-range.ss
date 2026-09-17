;; expect: #t
;; EXPECTED FAIL against src/prelude.ss at dac5b48.  A hash this runtime
;; computes can be larger than a fixnum, so the hash VALUE itself is a
;; bignum -- and $ht-index then pays bignum abs and remainder on every
;; lookup of that key, for as long as the key lives in the table.
;;
;; Measured: a key whose hash escapes the range costs about 2.1x per
;; lookup against one whose hash does not, over 200000 lookups, timed
;; alternating rather than one after the other.  The cost is not paid
;; once at insertion; $ht-index recomputes the hash every time.
;;
;; THIS IS NOT A WRONG ANSWER, and the cell says so rather than letting
;; a later reader inflate it.  R6RS asks a hash function only for an
;; exact non-negative integer, and these are; tables with such keys
;; behave correctly -- lookups hit, counts are right.  What is asserted
;; here is a PERFORMANCE CONTRACT this implementation chooses to hold:
;; every hash it computes stays inside the fixnum range, because the
;; whole point of bounding the hash arithmetic is lost if the result
;; escapes anyway.  docs/limits.md records it as the deliberate
;; narrowing it is.
;;
;; WRITTEN AS AN INVARIANT, NOT A LIST.  One rule over a corpus, so a
;; branch nobody enumerated is covered by the same line.  The witnesses
;; below were not found by sampling: 31 is invertible modulo 2^29-1
;; (31^-1 = 34636833), so for the branches shaped (+ k (remainder (+ (*
;; 31 A) B) M)) the argument can be solved for directly.  A search would
;; not have found them -- the target window is twelve values wide out of
;; 536 million, about 2e-8 per try.
;;
;; The exception is the first one, which needs no construction at all
;; and is the cheapest and most reachable member of the family: abs is
;; (if (< n 0) (- 0 n) n), and 0 - -536870912 is 536870912, one past the
;; maximum.  That branch is the one EVERY integer key in every eq or eqv
;; table takes.
(import (rnrs))
(define M 536870911)
(define fails '())
(define (report label k h)
  (when (> h M)
    (set! fails (cons (list label 'hash h 'over-fixnum-by (- h M)) fails))))

;; THE INVARIANT: every hash this runtime computes stays within M.
(for-each
 (lambda (entry) (report (car entry) (cdr entry) (equal-hash (cdr entry))))
 (list (cons 'most-negative-fixnum -536870912)
       (cons 'bignum 1073741817)
       (cons 'ratio-a 17318416/3)
       (cons 'ratio-b 51955249/4)
       (cons 'ratio-c 484915661/5)
       (cons 'complex (make-rectangular 467597245 1))
       ;; CONTROL rows: ordinary keys are inside and must stay silent.
       ;; Without them a repair that clamped every hash to a constant
       ;; would satisfy every row above.
       (cons 'CONTROL-small-int 42)
       (cons 'CONTROL-string "abc")
       (cons 'CONTROL-pair '(1 2 3))
       (cons 'CONTROL-symbol 'alpha)
       (cons 'CONTROL-char #\a)
       (cons 'CONTROL-max-fixnum 536870911)))

;; A clamping repair would also have to keep DIFFERENT keys apart, so
;; the controls check spread as well as range: these must not collide.
(define (spread-ok? a b) (not (= (equal-hash a) (equal-hash b))))
(unless (spread-ok? 42 43)
  (set! fails (cons '(CONTROL-spread 42-and-43-hash-alike) fails)))
(unless (spread-ok? "abc" "abd")
  (set! fails (cons '(CONTROL-spread abc-and-abd-hash-alike) fails)))

(display (if (null? fails) #t fails))
