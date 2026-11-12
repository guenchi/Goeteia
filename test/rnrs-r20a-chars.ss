;; expect: #t
;; R6RS names goeteia did not bind (ledger R20, batch R20a):
;; the case-insensitive character and string comparisons, the case predicates and
;; foldcase, on ASCII.
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
        (list (char-ci=? #\a #\A) (char-ci=? #\a #\b) (char-ci=? #\a #\A #\a) (char-ci=? #\a #\A #\b) (char-ci=? #\1 #\1)))
      '(#t #f #t #f #t))
(want 2
      (guard (c (#t 'raised))
        (list (char-ci<? #\a #\B) (char-ci<? #\B #\a) (char-ci<? #\a #\A) (char-ci<? #\a #\B #\c) (char-ci<? #\a #\C #\b)))
      '(#t #f #f #t #f))
(want 3
      (guard (c (#t 'raised))
        (list (char-ci>? #\B #\a) (char-ci>? #\a #\B) (char-ci>? #\c #\B #\a) (char-ci>? #\A #\a)))
      '(#t #f #t #f))
(want 4
      (guard (c (#t 'raised))
        (list (char-ci<=? #\a #\A) (char-ci<=? #\a #\B) (char-ci<=? #\B #\a) (char-ci<=? #\a #\A #\b)))
      '(#t #t #f #t))
(want 5
      (guard (c (#t 'raised))
        (list (char-ci>=? #\a #\A) (char-ci>=? #\B #\a) (char-ci>=? #\a #\B) (char-ci>=? #\c #\C #\b)))
      '(#t #t #f #t))
(want 6
      (guard (c (#t 'raised))
        (list (string-ci=? "Hello" "hELLO") (string-ci=? "Hello" "Help") (string-ci=? "" "") (string-ci=? "a" "A" "a") (string-ci=? "a" "A" "b") (string-ci=? "ab" "abc")))
      '(#t #f #t #t #f #f))
(want 7
      (guard (c (#t 'raised))
        (list (string-ci<? "apple" "Banana") (string-ci<? "Banana" "apple") (string-ci<? "abc" "ABD") (string-ci<? "ab" "ABC") (string-ci<? "a" "B" "c") (string-ci<? "abc" "ABC")))
      '(#t #f #t #t #t #f))
(want 8
      (guard (c (#t 'raised))
        (list (string-ci>? "Banana" "apple") (string-ci>? "apple" "Banana") (string-ci>? "c" "B" "a") (string-ci>? "ABC" "abc")))
      '(#t #f #t #f))
(want 9
      (guard (c (#t 'raised))
        (list (string-ci<=? "abc" "ABC") (string-ci<=? "abc" "ABD") (string-ci<=? "abd" "ABC") (string-ci<=? "a" "A" "b")))
      '(#t #t #f #t))
(want 10
      (guard (c (#t 'raised))
        (list (string-ci>=? "abc" "ABC") (string-ci>=? "abd" "ABC") (string-ci>=? "abc" "ABD") (string-ci>=? "b" "A" "a")))
      '(#t #t #f #t))
(want 11
      (guard (c (#t 'raised))
        (list (char-upper-case? #\A) (char-upper-case? #\a) (char-upper-case? #\1) (char-upper-case? #\space) (char-upper-case? #\Z)))
      '(#t #f #f #f #t))
(want 12
      (guard (c (#t 'raised))
        (list (char-lower-case? #\A) (char-lower-case? #\a) (char-lower-case? #\1) (char-lower-case? #\space) (char-lower-case? #\z)))
      '(#f #t #f #f #t))
(want 13
      (guard (c (#t 'raised))
        (list (char-foldcase #\A) (char-foldcase #\a) (char-foldcase #\Z) (char-foldcase #\1) (char-foldcase #\space)))
      '(#\a #\a #\z #\1 #\space))
(want 14
      (guard (c (#t 'raised))
        (list (string-foldcase "HeLLo, World 42") (string-foldcase "") (string-foldcase "abc")))
      '("hello, world 42" "" "abc"))
(want 15
      (guard (c (#t 'raised))
        (let ((s (string #\A #\b))) (list (string-foldcase s) s)))
      '("ab" "Ab"))
;; row 16 is goeteia's answer, not Chez's: goeteia folds A-Z only: every other character is its own fold and is neither upper nor lower case; Chez folds all of Unicode
(want 16
      (guard (c (#t 'raised))
        (let ((e (integer->char 233)) (E (integer->char 201))) (list (char-ci=? e E) (char=? (char-foldcase E) E) (char-upper-case? E) (char-lower-case? e) (string-ci=? (string e) (string E)) (char-ci=? e e))))
      '(#f #t #f #f #f #t))

(display (if (null? fails) #t (reverse fails)))
