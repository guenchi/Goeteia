;; expect: 5
;; The parameter-shadow sibling of
;; defect-spec-shadowed-primitive-in-operator-position.  That cell
;; shadows fl+ with a let; this one shadows it with a PARAMETER: g takes
;; fl+ as a formal, so inside g the head fl+ is g's argument, a lambda
;; returning the exact 5, not the primitive.  Before the fix the
;; specialiser read (fl+ x x) as a flonum expression, specialised zq's
;; parameter a to f64, and put that exact 5 in the slot -- an illegal
;; cast, exactly as the let-shadow case does.
;;
;; It is fixed by the same change and for the reason the code names: the
;; scope handed to fl-expr-in? at the call is (append shadowed hparams),
;; so it carries the enclosing function's parameters, and a parameter
;; can shadow a primitive's spelling as readily as a let can.  A cell was
;; owed because only let-shadow was exercised; the parameter case passed
;; already, but nothing was watching it.  It is a value cell, not a
;; product cell, because a wrong answer here is a miscompile, not a lost
;; specialisation.  Chez answers 5.
(import (rnrs))
(define (zq a b) (if (fl<? b 0.0) (zq (fl+ a 0.0) (fl+ b 1.0)) a))
(define (g fl+ x) (zq (fl+ x x) 0.0))
(display (g (lambda (p q) 5) 1.0))
