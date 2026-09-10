;; expect: #t
;; RED ON PURPOSE: <= and >= answer #t for a NaN, so a NaN compares as
;; ordered against everything including itself.
;;
;;              n<0   n>0   n<=0   n>=0   n=0   n=n   n<n   n>=n
;;   here       #f    #f     #t     #t    #f    #f    #f     #t
;;   Chez       #f    #f     #f     #f    #f    #f    #f     #f
;;
;; The shape of the error says where it came from: < and > are right
;; and <= and >= are wrong, which is what writing them as the negation
;; of the opposite strict comparison produces.  (not (> a b)) equals
;; (<= a b) for every pair of reals and differs on exactly one input --
;; a NaN, where IEEE 754 says all four comparisons are false because
;; the values are unordered rather than equal.
;;
;; (>= n n) answering #t is the one that does damage: it says a NaN
;; is ordered with respect to itself, so a sort or an ordered insert
;; will place it, and every later comparison against it lies too.  A
;; single NaN deadline in a priority queue permanently corrupts the
;; ordering invariant, and nothing raises.
;;
;; AND IT DEFEATS THE GUARD EVERY LIBRARY IN THIS TREE USES.  The
;; house form for "a non-negative real" is (and (real? x) (not (< x 0)))
;; -- twenty-two of those across (gam) and (web css) -- which a NaN
;; passes because (< nan 0) is false.  The obvious repair is to write
;; the positive form (>= x 0) instead, and that does not work either,
;; because >= is the broken one.  -> Fixing the guards without fixing
;; the predicate would look like a fix and change nothing.
;;
;; The controls are the ordinary orderings, because a repair that made
;; <= and >= reject more than NaN would break every loop in the tree.
(import (rnrs))
(define n (/ 0.0 0.0))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

;; ---- red ----
(want 'nan-le-zero (<= n 0.0) #f)
(want 'nan-ge-zero (>= n 0.0) #f)
(want 'nan-ge-itself (>= n n) #f)
(want 'nan-le-itself (<= n n) #f)

;; ---- already correct, kept so a repair cannot lose them ----
(want 'nan-lt-zero (< n 0.0) #f)
(want 'nan-gt-zero (> n 0.0) #f)
(want 'nan-eq-zero (= n 0.0) #f)
(want 'nan-eq-itself (= n n) #f)

;; ---- controls: ordinary reals must keep comparing ----
(want 'CONTROL-le-true (<= 1.0 2.0) #t)
(want 'CONTROL-le-equal (<= 2.0 2.0) #t)
(want 'CONTROL-le-false (<= 3.0 2.0) #f)
(want 'CONTROL-ge-true (>= 3.0 2.0) #t)
(want 'CONTROL-ge-equal (>= 2.0 2.0) #t)
(want 'CONTROL-ge-false (>= 1.0 2.0) #f)
(want 'CONTROL-exact-le (<= 1 1) #t)
(want 'CONTROL-mixed (<= 1 1.5) #t)
(want 'CONTROL-infinity (list (<= (/ 1.0 0.0) 0.0) (>= (/ 1.0 0.0) 0.0)) (list #f #t))

(if (null? fails) (display #t) (begin (display fails) (newline)))
