;; expect: (a)
;; C02, the contamination isolated: no library, no macro.  Defining car
;; at the top level and then displaying a one-element list prints the
;; user's value, because display reaches car by name inside the prelude.
;; Chez prints (a).
;;
;; This is the smallest spelling of the same fault
;; defect-prelude-capture-car.ss states, kept beside the oracle cells
;; because it names the reason oracle-a and oracle-a2 stay red after
;; the binding-identity slice: not the representation, the printer.  It
;; goes green when the prelude's own references are protected, and not
;; before.
(import (except (rnrs) car))
(define (car x) 'shadow)
(display (list 'a))
