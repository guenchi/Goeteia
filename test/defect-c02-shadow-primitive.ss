;; expect: 99
;; C02 (2026-09-06 review, still live 2026-09-09): a top-level
;; definition does not shadow a primitive of the same name.
;;
;; RED ON PURPOSE.  Today every target answers 1: the call site is
;; compiled as the primitive `car` however the program has bound the
;; name.  The primitive branch excludes known FUNCTIONS from
;; specialisation but not known VARIABLES, so a name the program
;; defines at top level is still treated as the builtin.
;;
;; ⚠️ Why it is worth a cell of its own rather than a line in a bigger
;; file: the failure is silent and the program is plausible.  A game
;; that defines its own `min`, `length` or `map` gets the builtin's
;; behaviour at every call and no diagnostic anywhere -- and the shape
;; is common enough that a caller reads their own definition, sees it is
;; right, and looks somewhere else.
;;
;; Reported location: src/compiler.ss:2099, src/js-backend.ss:653.
(import (rnrs))
(define car (lambda (x) 99))
(display (car (list 1)))
