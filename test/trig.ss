;; expect: #t
;; The prelude's sin/cos/tan: R6RS names, any-real input, answers
;; always flonums.  Accuracy for sin/cos is error < 1e-9 measured up
;; to |x| ~ 1e6; past that the single-step 2pi reduction degrades with
;; amplitude (measured ~2.4e-8 at 2^29), so the large-argument case
;; below is held to a deliberately coarser 1e-7 -- coarse enough to
;; pass, tight enough that a real break still trips it.  tan is the
;; quotient of those two and carries NO absolute bound of its own:
;; for t = s/c the first-order error is ds/c - s*dc/c^2 (the exact
;; form is (c*ds - s*dc)/(c*(c+dc))), so the numerator's error
;; is amplified by 1/cos and the denominator's by about 1/cos^2, and
;; tan CAN therefore degrade far faster than they do (~1.2e-9 at
;; x=942508, where cos x ~ 0.35, well inside the sin/cos domain and
;; nowhere near a pole).  At the poles it diverges outright (~5.6e-8
;; at 1.5707; infinity at the binary64 pi/2).  The tan cases below are
;; all small-argument ones and hold to the same bound as sin/cos; the
;; pole cases pin the divergence itself rather than an accuracy.
;;
;; An exact-1.0 expectation
;; anywhere would test the implementation rather than the contract:
;; the polynomial's own truncation at pi/2 is ~6e-12.  Oracle values
;; come from a host libm (Chez `scheme -q`, node `Math.sin`).
;; The matrix library's flsin/flcos/fltan must be ONE implementation
;; under two names; that requirement is checked textually in
;; test/trig-single-supply.mjs, for the reason given at the aliases
;; below.
(import (rnrs) (gfx mat))

(define fails 0)
(define (check name ok)
  (unless ok
    (display "FAIL ") (display name) (newline)
    (set! fails (+ fails 1))))
(define (near? a b tol)
  (and (flonum? a)
       (let ((d (fl- a b)))
         (fl<? (fl* d d) (fl* tol tol)))))
(define tol 0.000000001)                ; the documented error bound

(check "sin 0" (and (flonum? (sin 0)) (fl=? (sin 0) 0.0)))
(check "cos 0" (near? (cos 0) 1.0 tol))
(check "sin pi/2" (near? (sin 1.5707963267948966) 1.0 tol))
(check "cos pi" (near? (cos 3.141592653589793) -1.0 tol))
(check "sin -1.0" (near? (sin -1.0) -0.8414709848078965 tol))
(check "sin 10.0" (near? (sin 10.0) -0.5440211108893698 tol))
(check "sin 100" (near? (sin 100.0) -0.5063656411097588 tol))
;; tan away from the poles: both of these sit far inside the sin/cos
;; bound (measured ~5e-14 at 0.3 and ~5e-15 at 1), so both are held to
;; `tol` rather than to a looser figure.  Error here does not track
;; |tan x| -- it depends on the two errors and on cos x, and in fact
;; falls between these two points while the value rises.
(check "tan 0.3" (near? (tan 0.3) 0.3093362496096232 tol))
(check "tan 1" (near? (tan 1) 1.557407724654902 tol))
;; and the pole itself is documented behaviour, not an accident: the
;; quotient overflows to actual infinity, where a libm still answers a
;; finite ~1.63e16.  Pinned as infinity, not merely "very large": a
;; regression that returned a finite 1e19 would satisfy a threshold
;; while contradicting what the manual promises.
(check "tan at the pole is infinite"
       (let ((t (tan 1.5707963267948966))
             (inf (fl/ 1.0 0.0)))
         (and (flonum? t) (fl=? t inf))))
;; ...and at the NEXT pole it is -inf, while a libm answers +5.4e15:
;; the reduction lands cos exactly on zero, so the sign of the blow-up
;; is the numerator's alone and need not agree with a libm's.  Pinned
;; because "it overflows" would hide a sign a caller may branch on.
(check "the next pole blows up the other way"
       (let ((t (tan 4.71238898038469))
             (ninf (fl/ (fl- 0.0 1.0) 0.0)))
         (and (flonum? t) (fl=? t ninf))))

;; widened inputs: exact, ratio and bignum all convert, never trap
(check "sin exact" (near? (sin 1) 0.8414709848078965 tol))
(check "exact = flonum" (fl=? (sin 1) (sin 1.0)))
(check "ratio input" (fl=? (sin (/ 1 2)) (sin 0.5)))
;; a bignum argument: still a flonum, and still the right number to
;; within the degraded large-argument accuracy.  "It returns a
;; flonum" alone would stay green through a reduction that had
;; stopped reducing, which is the failure this pins.
;; (oracle: node -e 'Math.sin(536870912)' -> 0.3265676630185633)
(check "bignum input flonum" (flonum? (sin 536870912)))
(check "bignum input value"
       (near? (sin 536870912) 0.3265676630185633 0.0000001))

;; The matrix wrappers pass (fl* x 1.0) to keep the flonum layer's
;; parameter specialization alive program-wide.  That expression has
;; to be a true identity, and the input class where a plausible
;; substitute stops being one is negative zero: (fl+ x 0.0) collapses
;; -0.0 to +0.0, while multiplication keeps the sign.  sin(-0.0) is
;; -0.0 (as libm has it), so this goes red on that substitution.
;; (-0.0 is built here rather than written.  The reader had no working
;; -0.0 literal when this was written -- it collapsed to +0.0 -- and
;; now it has one; building it keeps this check independent of that.)
(define $neg-zero (fl* (fl- 0.0 1.0) 0.0))
(define (neg-zero? v) (fl<? (fl/ 1.0 v) 0.0))
(check "the fixture really is -0.0" (neg-zero? $neg-zero))
(check "flsin keeps the sign of zero" (neg-zero? (flsin $neg-zero)))
(check "sin keeps the sign of zero" (neg-zero? (sin $neg-zero)))

;; alias support: bit-identical answers under both names.  eq? would
;; be the real discriminator, but on the wasm target a top-level
;; function used as a value is wrapped in a FRESH closure struct at
;; every reference site (compile-fn-value), so procedure identity
;; does not survive two references even to one function; the hard
;; single-supply check is textual, in test/trig-single-supply.mjs.
(check "flsin = sin" (fl=? (flsin 0.5) (sin 0.5)))
(check "flcos = cos" (fl=? (flcos 2.0) (cos 2.0)))
(check "fltan = tan" (fl=? (fltan 0.7) (tan 0.7)))

(= fails 0)
