;; expect: #t
;; R6RS exception semantics, witnessed against Chez 10 (ledger R20f):
;; a guard that catches while it is itself leaving; a raise inside a handler.
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

(define (show c) (cond ((nc? c) 'NC) ((pair? c) (cons (show (car c)) (show (cdr c)))) (else c)))
(define cnt 0)
;; g1 G1, G2 pass 'a; D1's after raises 'f during G2's leave; G1 passes 'f; G2 (re-entered as a handler during its
;; own leave) CATCHES 'f: escape out of the outer chain for 'a
(run 'g1 (lambda ()
  (with-exception-handler (lambda (c) (note (list 'hout (show c))) 'o)
    (lambda () (list 'g2 (guard (e ((begin (note (list 't2 e)) (eq? e 'f)) 'g2-caught-f))
      (dynamic-wind (lambda () (note 'bef2)) (lambda ()
      (guard (e ((begin (note (list 't1 e)) #f) 'g1))
        (dynamic-wind (lambda () (note 'bef))
                        (lambda () (list 'r (raise 'a)))
                        (lambda () (note 'aft) (set! cnt (+ cnt 1)) (when (= cnt 2) (note (list 'aft-got (raise-continuable 'f))))))))
        (lambda () (note 'aft2)))) (raise-continuable 'post))))))
;; g2 raise; the chain G1 pass, h2 RAISES 'b (nested raise), G3 passes 'b, h4 returns for 'b: nc for 'b goes to
;; (G3 h4 R) -- under h2's raise's first handler G3? no: h2's raise has H = (G3 h4 R), first G3, nc under (h4 R)
(run 'g2 (lambda ()
  (with-exception-handler (lambda (c) (note (list 'h4 (show c))) 40)
    (lambda () (guard (e ((begin (note (list 't3 (show e))) #f) 'g3))
      (with-exception-handler (lambda (c) (note (list 'h2 (show c))) (raise (list 'b c)))
        (lambda () (guard (e ((begin (note (list 't1 (show e))) #f) 'g1))
          (list 'r (raise 'a))))))))))

(define expected
  '((g1 (g2 g2-caught-f o) (bef2 bef aft (t1 a) bef aft (t1 f) aft2 (t2 f) (hout post)))
    (g2 (escaped non-continuable) ((t1 a) (h2 a) (t3 (b a)) (h4 (b a)) (h4 NC)))))

(define (differing got want)
  (cond ((and (null? got) (null? want)) '())
        ((null? got) (list (list 'missing (car want))))
        ((null? want) (list (list 'extra (car got))))
        ((equal? (car got) (car want)) (differing (cdr got) (cdr want)))
        (else (cons (list 'got (car got) 'want (car want))
                    (differing (cdr got) (cdr want))))))
(display (let ((d (differing (reverse results) expected))) (if (null? d) #t d)))
