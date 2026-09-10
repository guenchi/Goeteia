;; expect: 99
;; Rewritten 2026-09-12 to the R6RS spelling: the user ruled that a
;; program may not define a name it imports, and that (except (rnrs)
;; car) makes the definition legal.  Under that ruling this cell asks
;; the only thing left to ask -- that the value form shadows the
;; program's own calls once the name is excluded -- and it stays red
;; until the import-discipline slice lands (design section 27).  The
;; comment below is the original, kept for the mechanism it names.
;; C02 (2026-09-06 review, still live 2026-09-09): a top-level
;; definition does not shadow a primitive of the same name.
;;
;; RED ON PURPOSE.  Today every target answers 1: the call site is
;; compiled as the primitive `car` however the program has bound the
;; name.  The primitive branch excludes known FUNCTIONS from
;; specialisation but not known VARIABLES, so a name the program
;; defines at top level is still treated as the builtin.
;;
;; Why it is worth a cell of its own rather than a line in a bigger
;; file: the failure is silent and the program is plausible.  A game
;; that defines its own `min`, `length` or `map` gets the builtin's
;; behaviour at every call and no diagnostic anywhere -- and the shape
;; is common enough that a caller reads their own definition, sees it is
;; right, and looks somewhere else.
;;
;; Reported location: src/compiler.ss:2099, src/js-backend.ss:653.
(import (except (rnrs) car))
(define car (lambda (x) 99))
(display (car (list 1)))
