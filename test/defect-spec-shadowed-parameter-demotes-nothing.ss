;; expect: 5
;; RED ON PURPOSE: a local that shadows an f64 parameter is taken for
;; the parameter it shadows, so a call that passes the local is not
;; demoted and an exact integer lands in an f64 slot.
;;
;; zq's parameter a is seeded f64 and nothing visible demotes it: the
;; only call from outside passes 5.0, and the recursive call passes
;; `a` -- which the demotion reads as the f64 parameter because
;; f64names is built from the enclosing function's formals and the
;; expression check cannot tell a shadowing local from the parameter
;; it shadows.  But that `a` is the let's exact 5.  Chez answers 5;
;; here the recursive call traps with an illegal cast.  Measured on
;; HEAD before any of the binding-form work, so this is not a
;; regression of it; found by a reviewer's fixture during that review.
;;
;; The recursive path has to be taken for the wrong operand to reach
;; the slot, which is what the -1.0 is for: with b = 0.0 the function
;; returns the local without recursing and every host prints 5.
(import (rnrs))
(define (zq a b) (let ((a 5)) (if (fl<? b 0.0) (zq a (fl+ b 1.0)) a)))
(display (zq 5.0 -1.0))
