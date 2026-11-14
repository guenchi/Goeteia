;; expect: #t
;; A read that fails because its argument is not an input port leaves
;; the reader as it was: later reads from real ports read (ledger R86).
;;
;; read switches the current input port inside a dynamic-wind, and the
;; switch stored the new port before it read the port's position.  For
;; something that is not a port the position read failed in the before
;; thunk, so the frame was never entered and its after thunk -- the
;; switch back -- never ran: every later read in the program then failed
;; on the stored non-port, whatever port it was given.
;;
;; ON THE TREE BEFORE THE CHANGE every read after the first failure is
;; refused, by an internal accessor.
(import (rnrs))

(define (rd s) (read (open-string-input-port s)))
(define (caught thunk) (guard (c (#t 'raised)) (thunk)))

(define got
  (list (caught (lambda () (read 5)))
        (caught (lambda () (rd "(3 4)")))
        (caught (lambda () (rd ")")))
        (caught (lambda () (rd "sym")))
        (caught (lambda () (read 'not-a-port)))
        (caught (lambda () (rd "#(1 \"two\")")))))

(display (if (equal? got '(raised (3 4) raised sym raised #(1 "two"))) #t got))
