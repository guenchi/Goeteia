;; expect: user(1 user)
;; RED ON PURPOSE: the program excludes append from (rnrs) and defines
;; its own, which R6RS allows.  Its own calls must reach its append;
;; the append that quasiquote's expansion introduces must still be the
;; prelude's, since that reference was written by the compiler.  Today
;; the definition is refused as "defined twice" because except is
;; advisory and a prelude procedure's name is a duplicate at the flat
;; top level.  Chez answers user then (1 user).  A reviewer's fixture
;; for the import-discipline slice (design section 27).
(import (except (rnrs) append))
(define (append . xs) (quote user))
(display (append (quote (1)) (quote (2))))
(display `(,@(quote (1)) ,(append (quote (2)) (quote (3)))))
