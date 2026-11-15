;; expect: #t
;; the comparisons take two or more arguments, as R6RS gives them (11.7.4.3,
;; 11.11, 11.12, 11.13 for fl; ledger R20): = < > <= >=, the char and
;; string comparisons and fl=? fl<? fl>? fl<=? fl>=?, called directly with
;; three or four arguments and as values; every argument is evaluated and
;; checked, also after a false pair; and not is a procedure, so it can be
;; passed and applied.
;;
;; Each row is an expression and the answer Chez 10 gives for it, compared
;; as a value; a row that raises answers `raised'.  A row marked OWN pins
;; goeteia's answer where R6RS leaves the matter open and Chez differs.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: a direct
;; call of < with three arguments is refused, and not is unbound as a
;; variable.
(import (rnrs))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 'lt3-true
      (guard (c (#t 'raised))
        (< 1 2 3))
      '#t)
(want 'lt3-false-first
      (guard (c (#t 'raised))
        (< 2 1 3))
      '#f)
(want 'lt3-false-second
      (guard (c (#t 'raised))
        (< 1 3 2))
      '#f)
(want 'lt4-true
      (guard (c (#t 'raised))
        (< 1 2 3 4))
      '#t)
(want 'gt3
      (guard (c (#t 'raised))
        (> 3 2 1))
      '#t)
(want 'le3
      (guard (c (#t 'raised))
        (<= 1 1 2))
      '#t)
(want 'ge3
      (guard (c (#t 'raised))
        (>= 2 2 1))
      '#t)
(want 'eq3-true
      (guard (c (#t 'raised))
        (= 1 1 1))
      '#t)
(want 'eq3-false
      (guard (c (#t 'raised))
        (= 1 1 2))
      '#f)
(want 'eq3-mixed
      (guard (c (#t 'raised))
        (= 1 1.0 1))
      '#t)
(want 'lt3-mixed
      (guard (c (#t 'raised))
        (< 1 3/2 2.0))
      '#t)
(want 'char-eq3
      (guard (c (#t 'raised))
        (char=? #\a #\a #\a))
      '#t)
(want 'char-lt3
      (guard (c (#t 'raised))
        (char<? #\a #\b #\c))
      '#t)
(want 'char-lt3-false
      (guard (c (#t 'raised))
        (char<? #\a #\c #\b))
      '#f)
(want 'char-gt3
      (guard (c (#t 'raised))
        (char>? #\c #\b #\a))
      '#t)
(want 'char-le3
      (guard (c (#t 'raised))
        (char<=? #\a #\a #\b))
      '#t)
(want 'char-ge3
      (guard (c (#t 'raised))
        (char>=? #\b #\b #\a))
      '#t)
(want 'string-eq3
      (guard (c (#t 'raised))
        (string=? "a" "a" "a"))
      '#t)
(want 'string-lt3
      (guard (c (#t 'raised))
        (string<? "a" "b" "c"))
      '#t)
(want 'string-lt3-false
      (guard (c (#t 'raised))
        (string<? "a" "c" "b"))
      '#f)
(want 'string-gt3
      (guard (c (#t 'raised))
        (string>? "c" "b" "a"))
      '#t)
(want 'string-le3
      (guard (c (#t 'raised))
        (string<=? "a" "a" "b"))
      '#t)
(want 'string-ge3
      (guard (c (#t 'raised))
        (string>=? "b" "b" "a"))
      '#t)
(want 'fl-eq3
      (guard (c (#t 'raised))
        (fl=? 1.0 1.0 1.0))
      '#t)
(want 'fl-lt3
      (guard (c (#t 'raised))
        (fl<? 1.0 2.0 3.0))
      '#t)
(want 'fl-gt3
      (guard (c (#t 'raised))
        (fl>? 3.0 2.0 1.0))
      '#t)
(want 'fl-le3
      (guard (c (#t 'raised))
        (fl<=? 1.0 1.0 2.0))
      '#t)
(want 'fl-ge3
      (guard (c (#t 'raised))
        (fl>=? 2.0 2.0 1.0))
      '#t)
(want 'fl-lt3-nan
      (guard (c (#t 'raised))
        (fl<? 1.0 +nan.0 2.0))
      '#f)
(want 'eval-once
      (guard (c (#t 'raised))
        (let ((n 0)) (< 1 (begin (set! n (+ n 1)) 2) 3) n))
      '1)
(want 'eval-after-false
      (guard (c (#t 'raised))
        (let ((n 0)) (< 3 2 (begin (set! n (+ n 1)) 1)) n))
      '1)
(want 'eval-after-false-char
      (guard (c (#t 'raised))
        (let ((n 0)) (char<? #\b #\a (begin (set! n (+ n 1)) #\c)) n))
      '1)
(want 'raises-lt-third
      (guard (c (#t 'raised))
        (< 1 2 'a))
      'raised)
(want 'raises-lt-after-false
      (guard (c (#t 'raised))
        (< 2 1 'a))
      'raised)
(want 'raises-char-after-false
      (guard (c (#t 'raised))
        (char<? #\b #\a 1))
      'raised)
(want 'raises-string-after-false
      (guard (c (#t 'raised))
        (string<? "b" "a" 1))
      'raised)
(want 'apply-lt3
      (guard (c (#t 'raised))
        (apply < '(1 2 3)))
      '#t)
(want 'apply-char3
      (guard (c (#t 'raised))
        (apply char<? (list #\a #\b #\c)))
      '#t)
(want 'apply-string3
      (guard (c (#t 'raised))
        (apply string<? '("a" "b" "c")))
      '#t)
(want 'var-gt4
      (guard (c (#t 'raised))
        (let ((f >)) (f 4 3 2 1)))
      '#t)
(want 'raises-apply-lt-one
      (guard (c (#t 'raised))
        (apply < '(1)))
      'raised)
(want 'raises-apply-char-one
      (guard (c (#t 'raised))
        (apply char<? (list #\a)))
      'raised)
(want 'not-map
      (guard (c (#t 'raised))
        (map not '(#t #f 1 ())))
      '(#f #t #f #f))
(want 'not-var
      (guard (c (#t 'raised))
        (let ((f not)) (f #f)))
      '#t)
(want 'not-procedure
      (guard (c (#t 'raised))
        (procedure? not))
      '#t)
(want 'not-apply
      (guard (c (#t 'raised))
        (apply not '(#f)))
      '#t)
(want 'raises-not-apply-two
      (guard (c (#t 'raised))
        (apply not '(#f 1)))
      'raised)
(want 'apply-lt3-third-pair-false
      (guard (c (#t 'raised))
        (apply < '(1 3 2)))
      '#f)
(want 'apply-eq3-third-pair-false
      (guard (c (#t 'raised))
        (apply = '(1 1 2)))
      '#f)
(want 'var-lt3-third-pair-false
      (guard (c (#t 'raised))
        (let ((f <)) (f 1 3 2)))
      '#f)
(want 'var-gt4-last-pair-false
      (guard (c (#t 'raised))
        (let ((f >)) (f 4 3 2 2)))
      '#f)
(want 'apply-char3-third-pair-false
      (guard (c (#t 'raised))
        (apply char<? (list #\a #\c #\b)))
      '#f)
(want 'apply-string3-third-pair-false
      (guard (c (#t 'raised))
        (apply string<? '("a" "c" "b")))
      '#f)
(want 'apply-fl3-third-pair-false
      (guard (c (#t 'raised))
        (apply fl<? '(1.0 3.0 2.0)))
      '#f)
(want 'map-three-lists
      (guard (c (#t 'raised))
        (map < '(1 1) '(2 0) '(3 5)))
      '(#t #f))
(want 'raises-apply-third-argument-checked
      (guard (c (#t 'raised))
        (apply < (list 1 2 'a)))
      'raised)

(display (if (null? fails) #t (reverse fails)))
