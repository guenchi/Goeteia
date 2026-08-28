;; expect: every exact value converts to the nearest double
;; $exact->fl rounds an exact rational to a double.  It scaled the
;; value into [2^53, 2^54), rounded there with a guard and a sticky
;; bit, and then handed the result to $fl-scale2 to put it at its real
;; exponent.  That last step is exact while the value stays normal --
;; and once it does not, every halving drops a bit and rounds AGAIN.
;;
;; So the rounding decision was made at 53 bits for a result that has
;; fewer, and "strictly above the halfway point" was absorbed by the
;; first rounding before the second one could see it.  $fl-scale2's own
;; comment named the condition ("exact until it can no longer be --
;; overflow, or the subnormal floor") and the code depended on it.
;;
;; Every expectation below is the correctly rounded value of an exact
;; rational, computed by exact rational arithmetic outside this tree:
;;
;;   python3 -c 'from fractions import Fraction as F; import struct
;;   print(struct.pack(">d", float(F(1, 10**317))).hex())'
;;
;; float(Fraction) is correctly rounded, so the oracle is the
;; definition rather than another implementation's opinion of it.
(import (rnrs) (gfx fx))

(define failures 0)
(define $hex "0123456789abcdef")
(define $bb (fx-alloc! 16))
(define (bits x)
  (%mem-f64-set! $bb x)
  (let loop ((i 7) (acc ""))
    (if (< i 0) acc
        (loop (- i 1)
              (let ((b (%mem-u8-ref (+ $bb i))))
                (string-append acc (string (string-ref $hex (quotient b 16))
                                           (string-ref $hex (remainder b 16)))))))))
(define (pw b n) (let loop ((i n) (a 1)) (if (= i 0) a (loop (- i 1) (* a b)))))

(define (cell tag num den want)
  (let* ((v (exact->inexact (/ num den))) (got (bits v)))
    (unless (string=? got want)
      (set! failures (+ failures 1))
      (display "  FAIL ") (display tag)
      (display ": want ") (display want)
      (display " got ") (display got) (newline))))

;; ---- the transition, one 2^-1074 step apart ------------------------
;; These three straddle the boundary the fix is about.  The middle one
;; is an EXACT halfway case whose upper neighbour is the smallest
;; normal, so ties-to-even must round UP and out of the subnormal
;; range: the carry leaves the precision it was rounded at.  A fix that
;; rounds at the right width but drops the carry lands on the largest
;; subnormal instead, and only this row can tell.
(cell "(2^54-3)/2^1076 largest subnormal"
      (- (pw 2 54) 3) (pw 2 1076) "000fffffffffffff")
(cell "(2^54-2)/2^1076 halfway, carries to normal"
      (- (pw 2 54) 2) (pw 2 1076) "0010000000000000")
(cell "(2^54-1)/2^1076 smallest normal"
      (- (pw 2 54) 1) (pw 2 1076) "0010000000000000")

;; ---- halfway cases at the very bottom, where one bit is left -------
(cell "1/2^1075 ties to even, down to zero" 1 (pw 2 1075) "0000000000000000")
(cell "3/2^1075 ties to even, up to two"    3 (pw 2 1075) "0000000000000002")
;; the decimal pair that first showed the defect: adjacent integers
;; over the same power of ten, landing either side of the halfway point
(cell "24703282292062328/10^340 -> smallest subnormal"
      24703282292062328 (pw 10 340) "0000000000000001")
(cell "24703282292062327/10^340 -> zero"
      24703282292062327 (pw 10 340) "0000000000000000")

;; ---- the end where the target precision clamps to zero -------------
(cell "1/2^1076 below half the smallest subnormal" 1 (pw 2 1076) "0000000000000000")
;; far below it, where the width would run to thousands of bits and is
;; clamped instead.  The sign still has to survive a magnitude that
;; rounds entirely away.
(cell "1/10^400"   1 (pw 10 400) "0000000000000000")
(cell "-1/10^400" -1 (pw 10 400) "8000000000000000")
(cell "1/10^4000"  1 (pw 10 4000) "0000000000000000")

;; ---- regression pins: everything that was already right ------------
;; The fix must be the mechanism's shape, not the symptom's.  These are
;; the values that were correct before it, and a fix reaching wider
;; than the defect shows up here first.
;; normal range, one ulp above a halfway point, both signs
(cell "r1 normal halfway+eps"  (+ (pw 2 200) (pw 2 147) 1) (pw 2 200) "3ff0000000000001")
(cell "r2 normal halfway+eps"  (+ (pw 2 200) (pw 2 147) 1) (pw 2 199) "4000000000000001")
(cell "-r1" (- 0 (+ (pw 2 200) (pw 2 147) 1)) (pw 2 200) "bff0000000000001")
(cell "-r2" (- 0 (+ (pw 2 200) (pw 2 147) 1)) (pw 2 199) "c000000000000001")
;; subnormals that need few bits were always right
(cell "3/2^1074" 3 (pw 2 1074) "0000000000000003")
(cell "(2^52-1)/2^1074" (- (pw 2 52) 1) (pw 2 1074) "000fffffffffffff")
;; the boundaries themselves
(cell "2^-1022 smallest normal" 1 (pw 2 1022) "0010000000000000")
(cell "2^-1074 smallest subnormal" 1 (pw 2 1074) "0000000000000001")

;; ---- the cross-host divergence this closes -------------------------
;; 1/10^317 sits 0.033 ulp above the halfway point between two
;; subnormals.  The Chez-hosted compiler read it correctly because
;; CHEZ's reader converted it; the self-hosted one used this converter
;; and answered one low.  Same source, two hosts, two values -- and the
;; gate could not see it because nothing exercised the literal.
(cell "1/10^317" 1 (pw 10 317) "00000000001ee257")
;; and its sign, since the sign travels separately to the conversion
(cell "-1/10^317" -1 (pw 10 317) "80000000001ee257")

(display (if (= failures 0)
             "every exact value converts to the nearest double"
             "SEE FAILURES ABOVE"))
