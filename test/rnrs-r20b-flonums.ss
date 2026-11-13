;; expect: #t
;; R6RS names goeteia did not bind (ledger R20, batch R20b):
;; the flonum comparisons, predicates, rounding, the fl div family, numerator
;; and denominator, flsin flcos fltan and real->flonum.
;;
;; Each row is an expression and the answer Chez 10 gives for it in (rnrs),
;; compared as a value.  A row that raises here answers `raised'.  A row
;; with a comment above it pins goeteia's own answer where its domain is
;; narrower than R6RS's.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: the names are
;; unbound.
(import (rnrs))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 1
      (guard (c (#t 'raised))
        (list (fl<=? 1.0 2.0) (fl<=? 2.0 2.0) (fl<=? 3.0 2.0) (fl<=? 1.0 2.0 2.0 3.0) (fl<=? 1.0 3.0 2.0)))
      '(#t #t #f #t #f))
(want 2
      (guard (c (#t 'raised))
        (list (fl>=? 2.0 1.0) (fl>=? 2.0 2.0) (fl>=? 1.0 2.0) (fl>=? 3.0 2.0 2.0 1.0) (fl>=? 3.0 1.0 2.0)))
      '(#t #t #f #t #f))
(want 3
      (guard (c (#t 'raised))
        (list (fl>? 2.0 1.0) (fl>? 2.0 2.0) (fl>? 1.0 2.0) (fl>? 3.0 2.0 1.0) (fl>? 3.0 2.0 2.0)))
      '(#t #f #f #t #f))
(want 4
      (guard (c (#t 'raised))
        (let ((nan (fl- (fl/ 1.0 0.0) (fl/ 1.0 0.0)))) (list (fl<=? nan 1.0) (fl>=? nan 1.0) (fl>? nan 1.0) (fl>? 1.0 nan))))
      '(#f #f #f #f))
(want 5
      (guard (c (#t 'raised))
        (list (flabs -2.5) (flabs 2.5) (flabs 0.0) (fl>? (fl/ 1.0 (flabs (fl* -1.0 0.0))) 0.0)))
      '(2.5 2.5 0.0 #t))
(want 6
      (guard (c (#t 'raised))
        (list (flmax 1.0 3.0 2.0) (flmin 1.0 3.0 2.0) (flmax 1.0) (flmin 4.0) (flmax -1.0 -2.0) (flmin -1.0 -2.0)))
      '(3.0 1.0 1.0 4.0 -1.0 -2.0))
(want 7
      (guard (c (#t 'raised))
        (let ((nan (fl- (fl/ 1.0 0.0) (fl/ 1.0 0.0)))) (list (flnan? (flmax 1.0 nan)) (flnan? (flmin nan 1.0)))))
      '(#t #t))
(want 8
      (guard (c (#t 'raised))
        (list (flzero? 0.0) (flzero? (fl* -1.0 0.0)) (flzero? 0.5) (flpositive? 0.5) (flpositive? 0.0) (flpositive? -0.5) (flnegative? -0.5) (flnegative? 0.0) (flnegative? (fl* -1.0 0.0))))
      '(#t #t #f #t #f #f #t #f #f))
(want 9
      (guard (c (#t 'raised))
        (list (flodd? 3.0) (flodd? 4.0) (fleven? 4.0) (fleven? 3.0) (flodd? -3.0) (fleven? 0.0)))
      '(#t #f #t #f #t #t))
(want 10
      (guard (c (#t 'raised))
        (let ((inf (fl/ 1.0 0.0))) (list (flinteger? 3.0) (flinteger? 3.5) (flinteger? inf) (flinteger? (fl- inf inf)) (flinteger? -2.0))))
      '(#t #f #f #f #t))
(want 11
      (guard (c (#t 'raised))
        (let ((inf (fl/ 1.0 0.0))) (list (flfinite? 1.5) (flfinite? inf) (flfinite? (fl- inf inf)) (flinfinite? inf) (flinfinite? (fl* -1.0 inf)) (flinfinite? 1.5) (flinfinite? (fl- inf inf)) (flnan? (fl- inf inf)) (flnan? inf) (flnan? 1.5))))
      '(#t #f #f #t #t #f #f #t #f #f))
(want 12
      (guard (c (#t 'raised))
        (list (flceiling 2.1) (flceiling 2.0) (flceiling -2.1) (flceiling -2.9) (flceiling 0.5)))
      '(3.0 2.0 -2.0 -2.0 1.0))
(want 13
      (guard (c (#t 'raised))
        (list (flround 2.5) (flround 3.5) (flround -2.5) (flround -3.5) (flround 2.4) (flround 2.6) (flround 0.5) (flround 1.5)))
      '(2.0 4.0 -2.0 -4.0 2.0 3.0 0.0 2.0))
(want 14
      (guard (c (#t 'raised))
        (list (fldiv 7.5 2.0) (flmod 7.5 2.0) (fldiv -7.5 2.0) (flmod -7.5 2.0) (fldiv 7.5 -2.0) (flmod 7.5 -2.0) (fldiv -7.5 -2.0) (flmod -7.5 -2.0)))
      '(3.0 1.5 -4.0 0.5 -3.0 1.5 4.0 0.5))
(want 15
      (guard (c (#t 'raised))
        (list (fldiv0 7.5 2.0) (flmod0 7.5 2.0) (fldiv0 -7.5 2.0) (flmod0 -7.5 2.0) (fldiv0 7.0 2.0) (flmod0 7.0 2.0) (fldiv0 -7.0 2.0) (flmod0 -7.0 2.0)))
      '(4.0 -0.5 -4.0 0.5 4.0 -1.0 -3.0 -1.0))
(want 16
      (guard (c (#t 'raised))
        (list (call-with-values (lambda () (fldiv-and-mod 7.5 2.0)) list) (call-with-values (lambda () (fldiv-and-mod -7.5 2.0)) list) (call-with-values (lambda () (fldiv0-and-mod0 7.5 2.0)) list) (call-with-values (lambda () (fldiv0-and-mod0 -7.0 2.0)) list)))
      '((3.0 1.5) (-4.0 0.5) (4.0 -0.5) (-3.0 -1.0)))
(want 17
      (guard (c (#t 'raised))
        (list (flnumerator 0.75) (fldenominator 0.75) (flnumerator 2.0) (fldenominator 2.0) (flnumerator -1.5) (fldenominator -1.5) (flnumerator 0.0) (fldenominator 0.0)))
      '(3.0 4.0 2.0 1.0 -3.0 2.0 0.0 1.0))
(want 18
      (guard (c (#t 'raised))
        (list (fl<? (flabs (flsin 0.0)) 0.000000001) (fl<? (flabs (fl- (flcos 0.0) 1.0)) 0.000000001) (fl<? (flabs (fltan 0.0)) 0.000000001)))
      '(#t #t #t))
(want 19
      (guard (c (#t 'raised))
        (list (fl<? (flabs (fl- (flsin 1.0) 0.8414709848078965)) 0.000000001) (fl<? (flabs (fl- (flcos 1.0) 0.5403023058681398)) 0.000000001) (fl<? (flabs (fl- (fltan 1.0) 1.5574077246549023)) 0.000000001)))
      '(#t #t #t))
(want 20
      (guard (c (#t 'raised))
        (list (real->flonum 1) (real->flonum -3) (real->flonum (/ 1 2)) (real->flonum 2.5) (real->flonum (* 65536 65536 65536)) (flonum? (real->flonum 7))))
      '(1.0 -3.0 0.5 2.5 2.81474976710656e14 #t))

(display (if (null? fails) #t (reverse fails)))
