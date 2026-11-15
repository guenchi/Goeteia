;; expect: #t
;; A Scheme procedure that JS calls receives as many of JS's arguments as it
;; accepts, and the surplus is dropped, as a JS function drops it; one that
;; needs more than JS passes still fails, reported through the callback
;; error hook -- here a counting one (ledger R65, batch M54 rule 8).  Calls
;; between Scheme procedures keep counting exactly.  Array.prototype.forEach
;; calls its callback with three arguments: the element, its index and the
;; array.
;;
;; ON THE TREE BEFORE THE CHANGE (6bdfbbd) the surplus was dropped by the
;; generic entry for every call, Scheme to Scheme included, and too few
;; arguments trapped, so the last row ends the program.  With the count
;; checked and the boundary not adapted, the three fixed-parameter
;; callbacks are refused and their bodies never run.
(import (rnrs) (web js))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define arr (js-new (js-get (js-global) "Array") 10 20 30))
(define out '())
(define (note! x) (set! out (cons x out)))
(define (take!) (let ((r (reverse out))) (set! out '()) r))
(js-method arr "forEach" (lambda (x) (note! (js->number x))))
(want 'one-parameter (take!) '(10 20 30))
(js-method arr "forEach" (lambda () (note! 'x)))
(want 'no-parameter (take!) '(x x x))
(js-method arr "forEach" (lambda (x i) (note! (list (js->number x) (js->number i)))))
(want 'two-parameters (take!) '((10 0) (20 1) (30 2)))
(js-method arr "forEach" (lambda args (note! (length args))))
(want 'rest-takes-all (take!) '(3 3 3))
(js-method arr "forEach" (lambda (x . r) (note! (length r))))
(want 'one-and-rest (take!) '(2 2 2))
;; inside Scheme the count is exact, the boundary notwithstanding
(want 'scheme-to-scheme-still-exact
      (guard (c ((assertion-violation? c) 'assertion) (#t 'other))
        (apply (lambda (x) x) '(1 2)))
      'assertion)
;; four parameters, three arguments: refused, the body does not run, and
;; each refusal reaches the callback error hook as an &assertion.  The hook
;; is installed for this row only, so the refusals are counted here rather
;; than reported on the console (where the test runner would rightly take
;; them for failures), and the default report is restored after it.
(define reports '())
(js-callback-error!
 (lambda (e) (set! reports (cons (if (assertion-violation? e) 'assertion 'other) reports))))
(js-method arr "forEach" (lambda (a b c d) (note! 'ran)))
(js-callback-error! #f)
(want 'more-parameters-than-arguments (list (take!) reports)
      '(() (assertion assertion assertion)))
(display (if (null? fails) #t (reverse fails)))
