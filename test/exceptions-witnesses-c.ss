;; expect: #t
;; R6RS exception semantics, witnessed against Chez 10 (ledger R20f):
;; two witnesses that fail if a frame is ever entered again in a fresh list cell.
;;
;; Every `run' evaluates a thunk under one outermost guard and records
;; (name value trace); the trace is what the thunks noted, in order.  The
;; expected list is what Chez prints for this same text with its own
;; dynamic-wind, with-exception-handler, raise, raise-continuable, guard
;; and call/cc.  goeteia's continuations only escape; these rows are the
;; ones that say a guard which does not match still behaves as if the
;; body had been left and entered again.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile
;; (with-exception-handler is unbound).
(import (rnrs))
(define kk #f)
(define trace '())
(define (note x) (set! trace (cons x trace)))
(define (nc? c) (and (condition? c) (non-continuable-violation? c)))
(define results '())
(define (shown c)
  (if (condition? c)
      (if (non-continuable-violation? c) 'non-continuable 'condition)
      c))
(define (run name thunk)
  (set! trace '())
  (let ((v (guard (c (#t (list 'escaped (shown c)))) (thunk))))
    (set! results (cons (list name v (reverse trace)) results))))

(define (hret c) (note (list 'h c)) 1)
;; q1 an outer guard's test escapes into the body, past an inner guard; the inner guard then catches a raise
(run 'q1 (lambda () (with-exception-handler hret
  (lambda () (let* ((g (guard (e ((and (eq? e 'x) (kk 'via-test)) 'never))
                         (dynamic-wind (lambda () (note 'in1))
                           (lambda () (guard (e ((eq? e 'y) (note 'g2-caught) 'g2))
                                        (dynamic-wind (lambda () (note 'in2))
                                          (lambda () (let ((v (call/cc (lambda (k) (set! kk k) (raise 'x)))))
                                                       (note (list 'resumed v)) (raise 'y)))
                                          (lambda () (note 'out2)))))
                           (lambda () (note 'out1)))))
                    (p (raise-continuable 'post)))
               (list g p))))))
;; q2 the same re-entry, then a continuation taken inside the outer frame BEFORE the re-entry is used
(run 'q2 (lambda () (with-exception-handler hret
  (lambda () (let* ((g (guard (e ((and (eq? e 'x) (kk 'via-test)) 'never))
                         (dynamic-wind (lambda () (note 'in1))
                           (lambda () (list 'f1 (call/cc (lambda (kout)
                                        (dynamic-wind (lambda () (note 'in2))
                                          (lambda () (let ((v (call/cc (lambda (k) (set! kk k) (raise 'x)))))
                                                       (note (list 'resumed v)) (kout 'kout)))
                                          (lambda () (note 'out2)))))))
                           (lambda () (note 'out1)))))
                    (p (raise-continuable 'post)))
               (list g p))))))

(define expected
  '((q1 (g2 1) (in1 in2 out2 in2 out2 out1 in1 in2 (resumed via-test) out2 g2-caught out1 (h post)))
    (q2 ((f1 kout) 1) (in1 in2 out2 out1 in1 in2 (resumed via-test) out2 out1 (h post)))))

(define (differing got want)
  (cond ((and (null? got) (null? want)) '())
        ((null? got) (list (list 'missing (car want))))
        ((null? want) (list (list 'extra (car got))))
        ((equal? (car got) (car want)) (differing (cdr got) (cdr want)))
        (else (cons (list 'got (car got) 'want (car want))
                    (differing (cdr got) (cdr want))))))
(display (let ((d (differing (reverse results) expected))) (if (null? d) #t d)))
