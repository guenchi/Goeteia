;; expect: (b1 in1 a1 b2 pre a2 b3 in3 a3 42)
(define log '())
(define (note x) (set! log (cons x log)))
;; plain in/out
(dynamic-wind (lambda () (note 'b1))
              (lambda () (note 'in1) 1)
              (lambda () (note 'a1)))
;; escape runs the after thunk on the way out
(note
 (call/cc
  (lambda (k)
    (dynamic-wind (lambda () (note 'b2))
                  (lambda () (note 'pre) (k 'a2-ran) (note 'never))
                  (lambda () (note 'a2))))))
(set! log (cdr log))  ; drop the escape's value marker
;; nested winds unwind inner-to-outer
(call/cc
 (lambda (k)
   (dynamic-wind (lambda () (note 'b3))
                 (lambda ()
                   (dynamic-wind (lambda () (note 'in3))
                                 (lambda () (k 0))
                                 (lambda () (note 'a3))))
                 (lambda () #f))))
(note 42)
(display (reverse log))
