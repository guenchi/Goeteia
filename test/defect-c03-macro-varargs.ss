;; expect: 6
;; C03 (2026-09-06 review, still live 2026-09-09): the macro evaluator
;; silently drops arguments past the second.
;;
;; RED ON PURPOSE.  Today every target answers 3: inside a transformer,
;; `(+ 1 2 3)` is folded by a meta-primitive that takes two arguments
;; and discards the rest.  `(append '(1) '(2) '(3))` loses the third
;; list the same way.
;;
;; ⚠️ Nothing is reported.  A macro that computes a wrong number emits a
;; program that compiles, runs, and is wrong -- and the wrongness is
;; attributed to the macro's author, who wrote arithmetic that is
;; correct in every other position in the language.
;;
;; Reported location: src/compiler.ss:732,747 (meta-prim).
(import (rnrs))
(define-syntax m
  (lambda (x) (datum->syntax x (+ 1 2 3))))
(display (m))
