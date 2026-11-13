;; expect: #t
;; js->number answers a JavaScript -0 as the flonum -0.0 (ledger R59).
;; An integral JS number in the fixnum range comes back as a fixnum, and
;; -0 is integral, so it came back as the exact 0 and lost its sign.
;; Controls: 0 and -5 still come back exact, 2.5 as a flonum.
;;
;; ON THE TREE BEFORE THE CHANGE the first row is (#f #f #f).
(import (rnrs) (web js))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))

(let ((x (js->number (js-eval "-0"))))
  (want 'negative-zero
        (list (flonum? x) (eqv? x -0.0) (and (flonum? x) (fl<? (fl/ 1.0 x) 0.0)))
        '(#t #t #t)))
(want 'zero (let ((x (js->number (js-eval "0")))) (list (exact? x) x)) '(#t 0))
(want 'minus-five (let ((x (js->number (js-eval "-5")))) (list (exact? x) x)) '(#t -5))
(want 'fraction (let ((x (js->number (js-eval "2.5")))) (list (flonum? x) x)) '(#t 2.5))

(display (if (null? fails) #t (reverse fails)))
