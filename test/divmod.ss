;; expect: #t
;; R6RS integer division: div/mod floor the remainder into [0, |d|),
;; div0/mod0 center it in [-|d|/2, |d|/2) -- the interval is closed
;; below and OPEN above, which is what the halfway cases probe.
;; Three layers: the algebra over a sign table, oracle values pinned
;; against a host R6RS (Chez, via `scheme -q`), and the fixnum
;; boundary where an answer crosses representation.  The contract is
;; exact integers only (narrower than R6RS's reals, by design): a
;; flonum, a ratio or a zero divisor must be an error, not a number.
(import (rnrs))

(define fails 0)
(define (check name ok)
  (unless ok
    (display "FAIL ") (display name) (newline)
    (set! fails (+ fails 1))))
(define (raises? thunk)
  (guard (e (#t #t)) (thunk) #f))

;; ---- layer 1: the algebra, all sign combinations ----
;; x = y*(div x y) + (mod x y)         with 0 <= mod < |y|
;; x = y*(div0 x y) + (mod0 x y)       with -|y|/2 <= mod0 < |y|/2
(define (laws-hold? x y)
  (let ((q (div x y)) (r (mod x y))
        (q0 (div0 x y)) (r0 (mod0 x y))
        (ay (abs y)))
    (and (= x (+ (* y q) r))
         (<= 0 r) (< r ay)
         (= x (+ (* y q0) r0))
         (<= (- 0 ay) (* 2 r0)) (< (* 2 r0) ay))))
(for-each
 (lambda (x)
   (for-each
    (lambda (y)
      (check (list 'laws x y) (laws-hold? x y)))
    '(2 -2 3 -3)))
 '(7 -7 8 -8 5 -5))

;; ---- layer 2: oracle values (generated with Chez) ----
(check "div -7 2" (= (div -7 2) -4))
(check "mod -7 2" (= (mod -7 2) 1))
(check "div0 -7 2" (= (div0 -7 2) -3))
(check "mod0 -7 2" (= (mod0 -7 2) -1))
(check "div0 5 2" (= (div0 5 2) 3))
(check "mod0 5 2" (= (mod0 5 2) -1))
(check "div0 8 3" (= (div0 8 3) 3))
(check "mod0 8 3" (= (mod0 8 3) -1))
(check "div0 8 -3" (= (div0 8 -3) -3))
(check "mod0 8 -3" (= (mod0 8 -3) -1))
;; negative divisors
(check "div 7 -3" (= (div 7 -3) -2))
(check "mod 7 -3" (= (mod 7 -3) 1))
(check "div0 7 -3" (= (div0 7 -3) -2))
(check "mod0 7 -3" (= (mod0 7 -3) 1))
(check "div -8 -3" (= (div -8 -3) 3))
(check "mod -8 -3" (= (mod -8 -3) 1))
(check "div0 -8 -3" (= (div0 -8 -3) 3))
(check "mod0 -8 -3" (= (mod0 -8 -3) 1))
;; a bignum dividend: -(2^40) (the language has no expt; literal)
(check "div bignum" (= (div -1099511627776 7) -157073089683))
(check "mod bignum" (= (mod -1099511627776 7) 5))
(check "div0 bignum" (= (div0 -1099511627776 7) -157073089682))
(check "mod0 bignum" (= (mod0 -1099511627776 7) -2))
;; both operands bignums: -(2^40+7) over 2^30+3
(check "div bn/bn" (= (div -1099511627783 1073741827) -1024))
(check "mod bn/bn" (= (mod -1099511627783 1073741827) 3065))
(check "div0 bn/bn" (= (div0 -1099511627783 1073741827) -1024))
(check "mod0 bn/bn" (= (mod0 -1099511627783 1073741827) 3065))

;; ---- layer 3: the fixnum boundary, which is ASYMMETRIC ----
;; fixnums run -536870912 .. 536870911 (one more on the negative
;; side), so the two ends are separate cases, not mirror images.
(check "div hi 2" (= (div 536870911 2) 268435455))
(check "div hi -2" (= (div 536870911 -2) -268435455))
(check "mod hi -2" (= (mod 536870911 -2) 1))
(check "div bn+ 2" (= (div 536870912 2) 268435456))
(check "div lo 2" (= (div -536870912 2) -268435456))
(check "mod lo 2" (= (mod -536870912 2) 0))
(check "div lo- -2" (= (div -536870913 -2) 268435457))
(check "mod lo- -2" (= (mod -536870913 -2) 1))
(check "laws at the edge"
       (and (laws-hold? 536870911 2) (laws-hold? 536870912 -2)
            (laws-hold? -536870912 3) (laws-hold? -536870913 -3)))
;; answers that CROSS the boundary come back as bignums
(check "div0 crosses up" (= (div0 1073741823 2) 536870912))
(check "mod0 at the cross" (= (mod0 1073741823 2) -1))
(check "crossed is not a fixnum" (not (fixnum? (div0 1073741823 2))))
(check "div crosses up" (= (div -1073741823 -2) 536870912))
(check "mod at the cross" (= (mod -1073741823 -2) 1))
(check "crossed is not a fixnum 2" (not (fixnum? (div -1073741823 -2))))
;; and ones that stay inside come back as fixnums -- including the
;; asymmetric negative end itself, which is a fixnum while its
;; positive mirror image is not
(check "inside is a fixnum" (fixnum? (div 536870911 2)))
(check "negative end is a fixnum" (fixnum? -536870912))
(check "one past it is not" (not (fixnum? -536870913)))
(check "positive mirror is not" (not (fixnum? 536870912)))

;; ---- the contract: zero divisor and non-integers are errors ----
(check "div by 0" (raises? (lambda () (div 5 0))))
(check "mod by 0" (raises? (lambda () (mod 5 0))))
(check "div0 by 0" (raises? (lambda () (div0 5 0))))
(check "mod0 by 0" (raises? (lambda () (mod0 5 0))))
;; the three flonum cases are the red evidence for the contract: drop
;; the exact-integer gate and they go green-through, answering a
;; number.  The ratio case covers the contract's surface but is NOT
;; red evidence -- without the gate it still raises, from the generic
;; quotient's own "unsupported operand combination".
(check "div flonum n" (raises? (lambda () (div 3.5 2))))
(check "mod flonum d" (raises? (lambda () (mod 7 2.0))))
(check "mod0 flonum" (raises? (lambda () (mod0 1.0 2))))
(check "div0 ratio" (raises? (lambda () (div0 (/ 1 2) 2))))

(= fails 0)
