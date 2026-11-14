;; expect: #t
;; How a condition is written (display and write alike): a simple
;; condition as any record is, #<NAME>; a compound condition as
;; #<condition NAME ...> with its components' type names, which is also
;; how the uncaught report writes it.  goeteia's own answers: R6RS does
;; not say, and Chez writes #<condition &error> and #<compound condition>.
;;
;; ON THE TREE BEFORE THE CHANGE a compound condition is written
;; #<$compound>, the prelude's own name for the type.
(import (rnrs))

(define (shown write-it x)
  (call-with-string-output-port (lambda (p) (write-it x p))))
(define (both x) (list (shown display x) (shown write x)))

(define got
  (list (both (make-error))
        (both (make-who-condition 'f))
        (both (condition (make-error) (make-who-condition 'f) (make-message-condition "m")))
        (both (condition))
        (both (list (condition (make-error) (make-warning))))
        (both (guard (e (#t e)) (error 'f "m" 1)))
        (both (guard (e (#t e)) (assert #f)))))

(define want
  '(("#<&error>" "#<&error>")
    ("#<&who>" "#<&who>")
    ("#<condition &error &who &message>" "#<condition &error &who &message>")
    ("#<condition>" "#<condition>")
    ("(#<condition &error &warning>)" "(#<condition &error &warning>)")
    ("#<condition &error &who &message &irritants>" "#<condition &error &who &message &irritants>")
    ("#<condition &assertion &who &message &irritants>" "#<condition &assertion &who &message &irritants>")))

(display (if (equal? got want) #t got))
