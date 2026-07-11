;; expect: #t
(define log '())
(define (note x) (set! log (cons x log)))
(and ;; catch a raised value
     (equal? (guard (e (#t (list 'caught e)))
               (raise 'boom)
               'never)
             '(caught boom))
     ;; normal completion passes through
     (eq? (guard (e (#t 'caught)) 'fine) 'fine)
     ;; clause dispatch and else
     (eq? (guard (e ((symbol? e) 'sym) ((number? e) 'num) (else 'other))
            (raise 42))
          'num)
     ;; unmatched clauses re-raise to the outer guard
     (eq? (guard (outer (#t 'outer-got-it))
            (guard (inner ((string? inner) 'wrong))
              (raise 'pass-through)))
          'outer-got-it)
     ;; dynamic-wind afters run while unwinding to the guard
     (begin
       (guard (e (#t #t))
         (dynamic-wind
           (lambda () (note 'in))
           (lambda () (raise 'x))
           (lambda () (note 'out))))
       (equal? (reverse log) '(in out)))
     ;; error makes a condition object
     (guard (e ((error? e)
                (and (eq? (condition-who e) 'me)
                     (string=? (condition-message e) "bad thing")
                     (equal? (condition-irritants e) '(1 2)))))
       (error 'me "bad thing" 1 2))
     ;; assert failures are guardable now
     (eq? (guard (e ((error? e) 'asserted))
            (assert (= 1 2)))
          'asserted))
