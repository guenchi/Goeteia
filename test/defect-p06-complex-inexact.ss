;; expect: #t
;; RED ON PURPOSE, and ALONE IN ITS FILE.
;;
;; (inexact z) on a complex number is an `illegal cast` -- a wasm trap.
;; A trap is not a Scheme condition: `guard` does not catch it, the
;; process stops, and every verdict the file had not yet printed is
;; lost.  This cell cannot share a file with anything, and the two
;; controls below run BEFORE it for the same reason.
;;
;; Chez answers 1.0+2.0i.  The review filed this as "inexact takes the
;; bignum conversion path for complex numbers"; measured, it does not
;; return a wrong number, it traps.
;;
;; What the fix must not do: make (real? z) answer #t.  A complex
;; number with a non-zero imaginary part is not real, and both this
;; implementation and Chez already agree on that -- measured, (#t #f)
;; from each.  A "fix" that widened real? would satisfy nothing here
;; but would be a worse error than the trap, so the control says so.
;; THE CONTROLS PRINT ONLY WHEN THEY FAIL, and the earlier version
;; of this file is why.  It displayed them unconditionally and then the
;; verdict, so the file wrote two lines while `;; expect:` carries one:
;; no implementation could ever pass it.  Worse, it stayed red
;; across the repair for two DIFFERENT reasons -- a trap before, a
;; mismatched expectation after -- so the one red hid the transition
;; from broken to fixed, and a reader watching only the runner's colour
;; would have concluded the fix had not taken.
;;
;; Passing cells are silent, exactly like every other cell in this
;; directory, so this file can be read the same way as the rest.  A
;; trap still ends the file, and that is still a failure: the runner
;; sees empty output where it wanted #t.
(import (rnrs))
(define z (make-rectangular 1 2))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name got expect) fails))))

;; controls first: they are the ones a trap would otherwise take with it
(want 'p06-CONTROL-number  (number? z) #t)
(want 'p06-CONTROL-not-real (real? z) #f)
(want 'p06-CONTROL-real-inexact (= 3.0 (inexact 3)) #t)
(unless (null? fails) (display fails) (newline))

(want 'p06-inexact-complex (equal? (inexact z) (make-rectangular 1.0 2.0)) #t)
(if (null? fails) (display #t) (display fails))
