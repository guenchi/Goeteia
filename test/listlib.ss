;; expect: #t
;; `list?` and circular chains.  A list is FINITE by definition, so a
;; chain that cycles is not one -- and the answer has to arrive.  The
;; old body put its recursive call in tail position, so on a circular
;; list it did not overflow: it span forever, silently, returning
;; nothing.  A wrong answer is caught by a table like this one; a HANG
;; is not, because a suite with no per-test timeout cannot tell "still
;; running" from "never returning".  So the cases below are the whole
;; report this file can give, and the run itself -- reaching the last
;; line at all -- is the other half of it.
(define circ (let ((l (list 1))) (set-cdr! l l) l))
(define circ2                          ; a longer cycle: the spine
  (let ((l (list 1 2 3)))              ; returns to its own head
    (set-cdr! (cdr (cdr l)) l)
    l))
(define elem-cycle                     ; the cycle is in an ELEMENT, and
  (list 1 2 circ))                     ; this spine is finite -- a list
(define lasso                          ; a tail that cycles, head does not
  (let ((tail (list 9)))
    (set-cdr! tail tail)
    (cons 1 tail)))
(and (eq? #f (list? circ))
     (eq? #f (list? circ2))
     (eq? #f (list? lasso))
     ;; and the neighbour it must not be confused with: a proper list
     ;; that HOLDS a circular one is still a list.  A check that walked
     ;; into elements would answer #f here and look just as correct
     ;; from the three rows above.
     (eq? #t (list? elem-cycle))
     ;; and the should-GREEN half: cycle detection that answers #f too
     ;; eagerly would read exactly the same from the three rows above
     (eq? #t (list? '()))
     (eq? #t (list? '(1)))
     (eq? #t (list? '(1 2 3 4 5)))
     (eq? #t (list? (map (lambda (i) i) '(1 2 3 4 5 6 7 8 9))))
     (eq? #f (list? (cons 1 2)))       ; improper, but finite
     (eq? #f (list? 7))
     (equal? (list 1 2 3) '(1 2 3))
     (eq? (length '(a b c)) 3)
     (equal? (append '(1 2) '(3 4)) '(1 2 3 4))
     (equal? (reverse '(1 2 3)) '(3 2 1))
     (equal? (map (lambda (x) (* x x)) '(1 2 3)) '(1 4 9))
     (equal? (memq 'b '(a b c)) '(b c))
     (equal? (assq 'y '((x 1) (y 2))) '(y 2))
     (let ((sum 0))
       (for-each (lambda (x) (set! sum (+ sum x))) '(1 2 3 4))
       (eq? sum 10)))
