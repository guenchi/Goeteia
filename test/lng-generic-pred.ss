;; expect: #t
;; (lng generic) predicate mode: open-ended predicates, ambiguity at call
;; time.  Predicate identity is eq? on the procedure object, so this file
;; needs the wasm target to give a top-level `(define (f ...))' ONE
;; identity across references (test/procedure-identity.ss); it is parked
;; in the archive until that lands.
(import (rnrs) (lng pred) (lng generic))
(define (refused? who thunk)
  (guard (e (#t (and (error? e) (eq? (condition-who e) who))))
    (thunk) #f))
;; ---- predicate mode: open-ended predicates, ambiguity at call time ----
(define (hot? s) (memq (car s) '(fire arcane)))
(define (fire? s) (eq? (car s) 'fire))
(define (squishy? t) (memq (cdr t) '(mage healer)))
(define (anyone? t) #t)
(define p1 (make-generic 'p1 2 'predicates))
(add-handlers! p1 (list (cons (list hot? anyone?) (lambda (s t) 'hot))
                        (cons (list fire? squishy?) (lambda (s t) 'fire-squishy))))
(define predicate-mode-ok
  (and (eq? (p1 '(arcane . 1) '(x . warrior)) 'hot)          ; only one applies
       ;; both apply, no declared relation: ambiguous, named after the generic
       (refused? 'p1 (lambda () (p1 '(fire . 1) '(x . mage))))
       (begin (declare-subset! fire? hot?) (declare-subset! squishy? anyone?) #t)
       (eq? (p1 '(fire . 1) '(x . mage)) 'fire-squishy)      ; now the more specific wins at every position
       ;; specific at one position, general at the other: still ambiguous
       (let ((p2 (make-generic 'p2 2 'predicates)))
         (add-handlers! p2 (list (cons (list fire? anyone?) (lambda (s t) 'a))
                                 (cons (list hot? squishy?) (lambda (s t) 'b))))
         (refused? 'p2 (lambda () (p2 '(fire . 1) '(x . mage)))))
       ;; a predicate cycle is refused
       (refused? 'declare-subset! (lambda () (declare-subset! hot? fire?)))
       ;; predicates run on every call: nothing is cached in predicate mode
       (let* ((n 0) (counting? (lambda (s) (set! n (+ n 1)) #t))
              (p4 (make-generic 'p4 1 'predicates)))
         (add-handler! p4 (list counting?) (lambda (s) 'x))
         (p4 '(fire . 1)) (p4 '(fire . 1))
         (= n 2))
       ;; the same predicate object twice is a duplicate; two closures with the same
       ;; body are two predicates (documented trap), so both register
       (let ((p3 (make-generic 'p3 1 'predicates)))
         (add-handler! p3 (list fire?) (lambda (s) 1))
         (and (refused? 'add-handler! (lambda () (add-handler! p3 (list fire?) (lambda (s) 2))))
              (begin (add-handler! p3 (list (lambda (s) (eq? (car s) 'fire))) (lambda (s) 3)) #t)
              (refused? 'p3 (lambda () (p3 '(fire . 1))))))))


predicate-mode-ok
