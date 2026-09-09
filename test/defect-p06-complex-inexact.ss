;; expect: #t
;; RED ON PURPOSE, and ALONE IN ITS FILE.
;;
;; (inexact z) on a complex number is an `illegal cast` -- a wasm trap.
;; ⚠️ A trap is not a Scheme condition: `guard` does not catch it, the
;; process stops, and every verdict the file had not yet printed is
;; lost.  ⇒ This cell cannot share a file with anything, and the two
;; controls below run BEFORE it for the same reason.
;;
;; Chez answers 1.0+2.0i.  The review filed this as "inexact takes the
;; bignum conversion path for complex numbers"; measured, it does not
;; return a wrong number, it traps.
;;
;; ⭐ What the fix must not do: make (real? z) answer #t.  A complex
;; number with a non-zero imaginary part is not real, and both this
;; implementation and Chez already agree on that -- measured, (#t #f)
;; from each.  A "fix" that widened real? would satisfy nothing here
;; but would be a worse error than the trap, so the control says so.
(import (rnrs))
(define z (make-rectangular 1 2))
;; controls first: whatever the trap takes with it, these are already out
(display (list (number? z) (real? z) (= 3.0 (inexact 3))))
(newline)
(display (equal? (inexact z) (make-rectangular 1.0 2.0)))
