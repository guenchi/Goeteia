;; expect: a
;; REGRESSION GUARD (written as a red witness at 8514ae1; green since).
;; The defect as it then was: R6RS case compares with eqv?, and this
;; expansion compares with eq?, so a flonum datum never matches. No
;; program definition is involved: this is a semantic defect of case
;; itself, found while writing the capture cells. Chez answers a.
(import (rnrs))
(display (case 1.5 ((1.5) (quote a)) (else (quote b))))
