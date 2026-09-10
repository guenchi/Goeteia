;; expect: 3
;; The same fault as defect-prelude-capture-null.ss, with an observable
;; that does not trap.  That file defines null? to answer #f, so every
;; prelude list walker reads past the end of its list and the run ends
;; in an illegal cast -- a trap, which is not a Scheme condition and
;; which takes the rest of the file's verdicts with it.  Its row count
;; therefore says more than it checked.
;;
;; Here null? answers #t instead, so the walkers stop early and give a
;; WRONG VALUE rather than a trap: length of a three-element list comes
;; back 0.  Chez says 3.  This is the row to cite as evidence for the
;; null? capture; the trapping one is kept because a trap is a real
;; consequence a user will meet.
(import (rnrs))
(define (null? x) #t)
(display (length '(1 2 3)))
