;; expect: hit
;; REGRESSION GUARD (written as a red witness at 8514ae1; green since).
;; The defect as it then was: case with several data per clause
;; dispatches through the same bare eq? as the single-datum form; see
;; defect-c02-synth-case-eq. Chez answers hit; here the stack is
;; exhausted.
(import (except (rnrs) eq?))
(define (eq? a b) #f)
(display (case 2 ((1 2 3) (quote hit)) (else (quote miss))))
