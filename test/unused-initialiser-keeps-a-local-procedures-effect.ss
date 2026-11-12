;; expect: boo boo boo end
;; A top-level definition nobody uses is dropped only when its initialiser
;; has no effect.  An initialiser that CALLS A LOCAL PROCEDURE named list,
;; vector or cons is not a constructor call: the local procedure may do
;; anything.  The judgement used to read the head by its spelling, took the
;; call for the constructor, and dropped the definition together with the
;; effect.  The fourth definition does use the real list and may go.
(import (rnrs))
(define unused-1 (let ((list (lambda (x) (display "boo ") x))) (list 1)))
(define unused-2 (let ((vector (lambda (x) (display "boo ") x))) (vector 1)))
(define unused-3 (let ((cons (lambda (x y) (display "boo ") x))) (cons 1 2)))
(define unused-4 (list 1 2 3))
(display "end")
