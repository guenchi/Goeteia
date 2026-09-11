;; expect: 5
;; Shadowed-primitive family, let* shape.  fl+ is shadowed by a
;; let* binding, so in operator position it is that binding, a lambda
;; returning the exact 5, not the primitive.  Before the operator-
;; position fix the specialiser read (fl+ ...) as a flonum expression,
;; specialised zq's parameter a to f64, and put the exact 5 in the slot:
;; an illegal cast.  Measured illegal cast on committed ef799c8 and 5
;; here; this shape was broken on HEAD and fixed with nothing watching
;; it until this cell.  A value cell, not a product cell, because a
;; wrong answer is a miscompile, and because in a shadowed shape
;; demoting is the correct outcome, so there is no specialisation to
;; watch losing.  One of six binding forms in the family; internal
;; define and letrec were never broken and get no cell.  Chez answers 5.
(import (rnrs))
(define (zq a b) (if (fl<? b 0.0) (zq (fl+ a 0.0) (fl+ b 1.0)) a))
(display (let* ((fl+ (lambda (x y) 5))) (zq (fl+ 1.0 2.0) 0.0)))
