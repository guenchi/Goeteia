;; expect: #t
;; R6RS exception semantics, witnessed against Chez 10 (ledger R20f):
;; a guard re-entered as a handler during its own leave; tests that escape into another
;; guard's body.
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
;; e1 G1 and G2 adjacent, both pass 'a; the after thunk of D1 (inside G1) raises 'f during G2's leave: it goes to
;; G1 (re-entrantly, G1 already passed) then to G2 (whose own leave is in progress), then hout
(run 'e1 (lambda ()
  (with-exception-handler (lambda (c) (note (list 'hout (show c))) 'o)
    (lambda () (guard (e ((begin (note (list 't2 e)) #f) 'g2))
      (guard (e ((begin (note (list 't1 e)) #f) 'g1))
        (dynamic-wind (lambda () (note 'bef))
                        (lambda () (list 'r (raise-continuable 'a)))
                        (lambda () (note 'aft) (set! cnt (+ cnt 1)) (when (= cnt 2) (note (list 'aft-got (raise-continuable 'f))))))))))))
;; e2 the same, but G1 CATCHES 'f: the escape goes to G1's continuation, inside G2's body, in the middle of G2's leave
(set! cnt 0)
(run 'e2 (lambda ()
  (with-exception-handler (lambda (c) (note (list 'hout (show c))) 'o)
    (lambda () (guard (e ((begin (note (list 't2 e)) #f) 'g2))
      (let ((g1 (guard (e ((begin (note (list 't1 e)) (eq? e 'f)) 'g1-caught-f))
                  (dynamic-wind (lambda () (note 'bef))
                                  (lambda () (list 'r (raise-continuable 'a)))
                                  (lambda () (note 'aft) (set! cnt (+ cnt 1)) (when (= cnt 2) (note (list 'aft-got (raise-continuable 'f)))))))))
        (list 'g2-body-continues g1 (raise-continuable 'post))))))))
;; e3 a before thunk raises 'b during G2's RE-ENTRY; G1 catches 'b
(set! cnt 0)
(run 'e3 (lambda ()
  (with-exception-handler (lambda (c) (note (list 'hout (show c))) 'o)
    (lambda () (guard (e ((begin (note (list 't2 e)) #f) 'g2))
      (let ((g1 (guard (e ((begin (note (list 't1 e)) (eq? e 'b)) 'g1-caught-b))
                  (dynamic-wind (lambda () (set! cnt (+ cnt 1)) (note (list 'bef cnt)) (when (= cnt 3) (raise-continuable 'b)))
                                  (lambda () (list 'r (raise 'a)))
                                  (lambda () (note 'aft))))))
        (list 'g2-body-continues g1 (raise-continuable 'post))))))))
;; e4 as e3, but nothing in the chain catches 'b; hout answers; then raise 'a goes on to hout, which returns: nc
(set! cnt 0)
(run 'e4 (lambda ()
  (with-exception-handler (lambda (c) (note (list 'hout (show c))) 'o)
    (lambda () (guard (e ((begin (note (list 't2 (show e))) #f) 'g2))
      (guard (e ((begin (note (list 't1 (show e))) #f) 'g1))
        (dynamic-wind (lambda () (set! cnt (+ cnt 1)) (note (list 'bef cnt)) (when (= cnt 3) (note (list 'bgot (raise-continuable 'b)))))
                        (lambda () (list 'r (raise 'a)))
                        (lambda () (note 'aft)))))))))
;; e5 &non-continuable after a chain where the returning handler is reached through a before thunk's raise
(set! cnt 0)
(run 'e5 (lambda ()
  (guard (e ((nc? e) (note 'outer-nc) 'outer-nc))
    (with-exception-handler (lambda (c) (note (list 'hmid (show c))) 'm)
      (lambda () (guard (e ((begin (note (list 't2 (show e))) (nc? e)) 'g2-nc))
        (guard (e ((begin (note (list 't1 (show e))) #f) 'g1))
          (dynamic-wind (lambda () (set! cnt (+ cnt 1)) (note (list 'bef cnt)))
                          (lambda () (list 'r (raise 'a)))
                          (lambda () (note 'aft))))))))))
;; e6 a guard's test escapes to a continuation captured in an EARLIER (passed) guard's body... and the earlier guard
;; catches the next raise
(define k1 #f)
(set! cnt 0)
(run 'e6 (lambda ()
  (with-exception-handler (lambda (c) (note (list 'hout (show c))) 'o)
    (lambda () (guard (e ((begin (note (list 't3 e)) (set! cnt (+ cnt 1)) (when (= cnt 1) (k1 'via-t3)) #f) 'g3))
      (guard (e ((begin (note (list 't2 e)) #f) 'g2))
        (guard (e ((begin (note (list 't1 e)) (eq? e 'second)) 'g1-caught))
          (dynamic-wind (lambda () (note 'bef))
                          (lambda () (let ((v (call/cc (lambda (k) (set! k1 k) (raise 'first)))))
                                       (note (list 'resumed v)) (raise 'second)))
                          (lambda () (note 'aft))))))))))

(define expected
  '((e1 (r o) (bef aft (t1 a) bef aft (t1 f) (t2 f) (hout f) (aft-got o) (t2 a) bef (hout a) aft))
    (e2 (g2-body-continues g1-caught-f o) (bef aft (t1 a) bef aft (t1 f) (t2 post) (hout post)))
    (e3 (g2-body-continues g1-caught-b o) ((bef 1) aft (t1 a) (bef 2) aft (t2 a) (bef 3) (t1 b) (t2 post) (hout post)))
    (e4 (escaped non-continuable) ((bef 1) aft (t1 a) (bef 2) aft (t2 a) (bef 3) (t1 b) (t2 b) (hout b) (bgot o) (hout a) aft (t2 NC) (bef 4) (hout NC) (hout NC) aft))
    (e5 g2-nc ((bef 1) aft (t1 a) (bef 2) aft (t2 a) (bef 3) (hmid a) aft (t2 NC)))
    (e6 g1-caught (bef aft (t1 first) bef aft (t2 first) bef aft (t3 first) bef (resumed via-t3) aft (t1 second)))))

(define (differing got want)
  (cond ((and (null? got) (null? want)) '())
        ((null? got) (list (list 'missing (car want))))
        ((null? want) (list (list 'extra (car got))))
        ((equal? (car got) (car want)) (differing (cdr got) (cdr want)))
        (else (cons (list 'got (car got) 'want (car want))
                    (differing (cdr got) (cdr want))))))
(display (let ((d (differing (reverse results) expected))) (if (null? d) #t d)))
