;; expect: user#(1 2 3)
;; The program excludes list->vector from (rnrs) and defines its own,
;; which R6RS allows.  Its own calls reach its list->vector; the
;; list->vector that VECTOR quasiquote's expansion introduces must still
;; reach the prelude's, because the compiler wrote that reference.  So
;; the user's call answers 'user and the quasiquoted vector is a real
;; vector, #(1 2 3), not 'user.
;;
;; This guards the SECOND compiler-introduced name in the quasiquote
;; path.  cons and append were already introduced here, and append has
;; c02-excluded-append-program-and-quasiquote; list->vector is new with
;; the vector clause and is the only cell watching that introduction.
;; codex settled its hygiene by reasoning that canonicalisation resolves
;; the introduced reference to the prelude's; this pins the same fact by
;; measurement, so a later change to compiler-introduced cannot break
;; vector quasiquote with nothing red.  Chez answers the same.
(import (except (rnrs) list->vector))
(define (list->vector xs) 'user)
(display (list->vector '(1)))
(write `#(1 ,(+ 1 1) 3))
