;; expect: #t
;; R6RS exception semantics, witnessed against Chez 10 (ledger R20f):
;; guards inside clause tests, after and before thunks that raise through their own guards,
;; one condition through three guards and a returning handler twice, a common tail that is empty.
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


(define cnt 0)
(define flag 0)
(define (hret c) (note (list 'h c)) 1)
;; r1 a guard nested in the clause TEST of an outer guard; the inner one does not match and its re-raise is
;; answered by the outer handler (which returns #t), so the outer clause matches; then a later raise
(run 'r1 (lambda () (with-exception-handler (lambda (c) (note (list 'h c)) #t)
  (lambda () (let* ((g (guard (e ((guard (e2 ((string? e2) 'inner-s))
                                      (dynamic-wind (lambda () (note 'tin))
                                                      (lambda () (raise-continuable (list 'in-test e)))
                                                      (lambda () (note 'tout))))
                                    (note 'clause) 'outer-matched))
                         (dynamic-wind (lambda () (note 'in)) (lambda () (raise 'a)) (lambda () (note 'out)))))
                    (p (raise-continuable 'post)))
               (list g p))))))
;; r1b the same, but the inner re-raise is answered #f: the outer guard does not match either and comes back
(run 'r1b (lambda () (with-exception-handler (lambda (c) (note (list 'h c)) (if (pair? c) #f 5))
  (lambda () (let* ((g (guard (e ((guard (e2 ((string? e2) 'inner-s))
                                      (dynamic-wind (lambda () (note 'tin))
                                                      (lambda () (raise-continuable (list 'in-test e)))
                                                      (lambda () (note 'tout))))
                                    'outer-matched))
                         (dynamic-wind (lambda () (note 'in)) (lambda () (+ 1 (raise-continuable 'a))) (lambda () (note 'out)))))
                    (p (raise-continuable 'post)))
               (list g p))))))
;; r2 an after thunk, run during the guard's leave AND at the normal exit, raises through a non-matching guard
;; of its own; the outer guard does not match either; the outermost handler returns each time
(run 'r2 (lambda () (with-exception-handler hret
  (lambda () (let* ((g (guard (e ((string? e) 's))
                         (dynamic-wind (lambda () (note 'in))
                           (lambda () (+ 10 (raise-continuable 'a)))
                           (lambda () (note 'out)
                             (note (list 'aret (guard (e3 ((string? e3) 's3))
                                                 (dynamic-wind (lambda () (note 'ain))
                                                                 (lambda () (raise-continuable 'b))
                                                                 (lambda () (note 'aout))))))))))
                    (p (raise-continuable 'post)))
               (list g p))))))
;; r2b the same, with a guard outside that catches the after thunk's object: the first leave is abandoned
(run 'r2b (lambda () (with-exception-handler hret
  (lambda () (let* ((g (guard (e ((eq? e 'b) (note 'g0) (list 'g0 e)))
                         (guard (e ((string? e) 's))
                           (dynamic-wind (lambda () (note 'in))
                             (lambda () (+ 10 (raise-continuable 'a)))
                             (lambda () (note 'out)
                               (note (list 'aret (guard (e3 ((string? e3) 's3))
                                                   (dynamic-wind (lambda () (note 'ain))
                                                                   (lambda () (raise-continuable 'b))
                                                                   (lambda () (note 'aout)))))))))))
                    (p (raise-continuable 'post)))
               (list g p))))))
;; r2c the after thunk's detour comes back; then the handler for the first object escapes into the body
(set! flag 0)
(run 'r2c (lambda () (with-exception-handler
                       (lambda (c) (note (list 'h c)) (if (and (eq? c 'a) (= flag 0)) (begin (set! flag 1) (kk 'jumped)) 1))
  (lambda () (let* ((g (guard (e ((string? e) 's))
                         (dynamic-wind (lambda () (note 'in))
                           (lambda () (list 'body (call/cc (lambda (k) (set! kk k) (+ 10 (raise-continuable 'a))))))
                           (lambda () (note 'out)
                             (note (list 'aret (guard (e3 ((string? e3) 's3))
                                                 (dynamic-wind (lambda () (note 'ain))
                                                                 (lambda () (raise-continuable 'b))
                                                                 (lambda () (note 'aout))))))))))
                    (p (raise-continuable 'post)))
               (list g p))))))
;; r3 a before thunk, run during the re-entry, raises through a non-matching guard of its own and comes back
(set! cnt 0)
(run 'r3 (lambda () (with-exception-handler hret
  (lambda () (let* ((g (guard (e ((string? e) 's))
                         (dynamic-wind
                           (lambda () (set! cnt (+ cnt 1)) (note (list 'in cnt))
                             (when (= cnt 2)
                               (note (list 'bret (guard (e3 ((string? e3) 's3))
                                                   (dynamic-wind (lambda () (note 'bin))
                                                                   (lambda () (raise-continuable 'b))
                                                                   (lambda () (note 'bout))))))))
                           (lambda () (+ 10 (raise-continuable 'a)))
                           (lambda () (note 'out)))))
                    (p (raise-continuable 'post)))
               (list g p))))))
;; r4 a test escapes into the body (continuation taken there); the body then raises a second object, caught
(run 'r4 (lambda () (with-exception-handler hret
  (lambda () (let* ((g (guard (e ((and (eq? e 'x) (kk 'via-test)) 'never) ((eq? e 'y) (note 'caught-y) 'y))
                         (dynamic-wind (lambda () (note 'in))
                           (lambda () (let ((v (call/cc (lambda (k) (set! kk k) (raise 'x)))))
                                        (note (list 'resumed v))
                                        (raise 'y)))
                           (lambda () (note 'out)))))
                    (p (raise-continuable 'post)))
               (list g p))))))
;; r4b the same, the second object matches nothing and the outer handler returns
(run 'r4b (lambda () (with-exception-handler hret
  (lambda () (let* ((g (guard (e ((and (eq? e 'x) (kk 'via-test)) 'never) ((eq? e 'y) 'y))
                         (dynamic-wind (lambda () (note 'in))
                           (lambda () (let ((v (call/cc (lambda (k) (set! kk k) (raise 'x)))))
                                        (note (list 'resumed v))
                                        (+ 100 (raise-continuable 'z))))
                           (lambda () (note 'out)))))
                    (p (raise-continuable 'post)))
               (list g p))))))
;; r5 one object through three non-matching guards and a returning handler, twice; then a third object that
;; the middle guard catches, then a later raise
(define (three tail)
  (guard (e ((eq? e 'z1) (note 'g1) 'g1))
    (dynamic-wind (lambda () (note 'in1))
      (lambda () (guard (e ((eq? e 'z2) (note 'g2) 'g2))
                   (dynamic-wind (lambda () (note 'in2))
                     (lambda () (guard (e ((eq? e 'z3) (note 'g3) 'g3))
                                  (dynamic-wind (lambda () (note 'in3))
                                    (lambda () (let* ((a (raise-continuable 'c)) (b (raise-continuable 'c))) (tail (+ a b))))
                                    (lambda () (note 'out3)))))
                     (lambda () (note 'out2)))))
      (lambda () (note 'out1)))))
(run 'r5 (lambda () (with-exception-handler hret
  (lambda () (let* ((g (three (lambda (s) (note (list 'sum s)) (raise 'z2))))
                    (p (raise-continuable 'post)))
               (list g p))))))
(run 'r5b (lambda () (with-exception-handler hret
  (lambda () (let* ((g (three (lambda (s) (note (list 'sum s)) (raise 'z1))))
                    (h (three (lambda (s) (note (list 'sum s)) (raise 'z3))))
                    (p (raise-continuable 'post)))
               (list g h p))))))
;; r6 a before thunk, run during the re-entry, escapes INTO the body (continuation taken inside its frame)
(set! cnt 0)
(run 'r6 (lambda () (with-exception-handler hret
  (lambda () (let* ((g (guard (e ((string? e) 's))
                         (dynamic-wind
                           (lambda () (set! cnt (+ cnt 1)) (note (list 'in cnt)) (when (= cnt 2) (kk 'from-before)))
                           (lambda () (list 'body (call/cc (lambda (k) (set! kk k) (+ 10 (raise-continuable 'a))))))
                           (lambda () (note 'out)))))
                    (p (raise-continuable 'post)))
               (list g p))))))
;; r7 a guard nested in a clause test whose re-raise reaches a handler that escapes into the outer guard's body
(set! flag 0)
(run 'r7 (lambda () (with-exception-handler
                      (lambda (c) (note (list 'h c)) (if (and (pair? c) (= flag 0)) (begin (set! flag 1) (kk 'from-h)) 1))
  (lambda () (let* ((g (guard (e ((guard (e2 ((string? e2) 'inner-s))
                                      (dynamic-wind (lambda () (note 'tin))
                                                      (lambda () (raise-continuable (list 'in-test e)))
                                                      (lambda () (note 'tout))))
                                    'outer-matched))
                         (dynamic-wind (lambda () (note 'in))
                           (lambda () (list 'body (call/cc (lambda (k) (set! kk k) (raise 'a)))))
                           (lambda () (note 'out)))))
                    (p (raise-continuable 'post)))
               (list g p))))))
;; r8 an after thunk's detour: the after thunk's own guard catches a raise that passed through the outer guard
(run 'r8 (lambda () (with-exception-handler hret
  (lambda () (let* ((g (guard (e ((string? e) 's))
                         (dynamic-wind (lambda () (note 'in))
                           (lambda () (+ 10 (raise-continuable 'a)))
                           (lambda () (note 'out)
                             (note (list 'aret (guard (e3 ((eq? e3 'b) (note 'caught-b) 'cb))
                                                 (with-exception-handler (lambda (c) (note (list 'ah c)) (raise-continuable c))
                                                   (lambda () (dynamic-wind (lambda () (note 'ain))
                                                                   (lambda () (raise-continuable 'b))
                                                                   (lambda () (note 'aout))))))))))))
                    (p (raise-continuable 'post)))
               (list g p))))))
;; top level: switch-to whose common tail is the empty list, with frames on both sides
(set! trace '())
(set! flag 0)
(define top (call/cc (lambda (out)
   (dynamic-wind (lambda () (note 'inA))
     (lambda () (dynamic-wind (lambda () (note 'inX))
                   (lambda () (list 'resumed (call/cc (lambda (kin) (set! kk kin) (out 'left)))))
                   (lambda () (note 'outX))))
     (lambda () (note 'outA)
        (when (= flag 0) (set! flag 1)
          (dynamic-wind (lambda () (note 'inB)) (lambda () (kk 'again)) (lambda () (note 'outB)))))))))
(set! results (cons (list 'top top (reverse trace)) results))
(set! results (cons (list 'top-post (guard (e (#t (list 'fresh e))) (raise 'later))) results))
(set! trace '())
(define top2 (with-exception-handler (lambda (c) (note (list 'th c)) 3) (lambda () (+ 1 (raise-continuable 'tp)))))
(set! results (cons (list 'top2 top2 (reverse trace)) results))

(define expected
  '((r1 (outer-matched #t) (in out tin tout tin (h (in-test a)) tout clause (h post)))
    (r1b (6 5) (in out tin tout tin (h (in-test a)) tout in (h a) out (h post)))
    (r2 (11 1) (in out ain aout ain aout ain (h b) aout (aret 1) in (h a) out ain aout ain aout ain (h b) aout (aret 1) (h post)))
    (r2b ((g0 b) 1) (in out ain aout ain aout ain aout g0 (h post)))
    (r2c ((body jumped) 1) (in out ain aout ain aout ain (h b) aout (aret 1) in (h a) out ain aout ain aout ain (h b) aout (aret 1) (h post)))
    (r3 (11 1) ((in 1) out (in 2) bin bout bin bout bin (h b) bout (bret 1) (h a) out (h post)))
    (r4 (y 1) (in out in (resumed via-test) out caught-y (h post)))
    (r4b (101 1) (in out in (resumed via-test) out in (h z) out (h post)))
    (r5 (g2 1) (in1 in2 in3 out3 in3 out3 out2 in2 in3 out3 out2 out1 in1 in2 in3 (h c) out3 in3 out3 out2 in2 in3 out3 out2 out1 in1 in2 in3 (h c) (sum 2) out3 in3 out3 out2 g2 out1 (h post)))
    (r5b (g1 g3 1) (in1 in2 in3 out3 in3 out3 out2 in2 in3 out3 out2 out1 in1 in2 in3 (h c) out3 in3 out3 out2 in2 in3 out3 out2 out1 in1 in2 in3 (h c) (sum 2) out3 in3 out3 out2 in2 in3 out3 out2 out1 g1 in1 in2 in3 out3 in3 out3 out2 in2 in3 out3 out2 out1 in1 in2 in3 (h c) out3 in3 out3 out2 in2 in3 out3 out2 out1 in1 in2 in3 (h c) (sum 2) out3 g3 out2 out1 (h post)))
    (r6 ((body from-before) 1) ((in 1) out (in 2) (in 3) out (h post)))
    (r7 ((body from-h) 1) (in out tin tout tin (h (in-test a)) tout in out (h post)))
    (r8 (11 1) (in out ain (ah b) aout caught-b (aret cb) in (h a) out ain (ah b) aout caught-b (aret cb) (h post)))
    (top (resumed again) (inA inX outX outA inB outB inA inX outX outA))
    (top-post (fresh later))
    (top2 4 ((th tp)))))

(define (differing got want)
  (cond ((and (null? got) (null? want)) '())
        ((null? got) (list (list 'missing (car want))))
        ((null? want) (list (list 'extra (car got))))
        ((equal? (car got) (car want)) (differing (cdr got) (cdr want)))
        (else (cons (list 'got (car got) 'want (car want))
                    (differing (cdr got) (cdr want))))))
(display (let ((d (differing (reverse results) expected))) (if (null? d) #t d)))
