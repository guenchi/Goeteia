;; expect: #t
;; each kind of error the prelude itself reports raises the condition type
;; R6RS names for it (ledger R20f, the second batch): &assertion for a
;; wrong argument or call, &lexical with &i/o-read from the reader,
;; &implementation-restriction for a result goeteia cannot represent,
;; &i/o-filename for a file that cannot be opened.
;;
;; Each row is an expression and the answer Chez 10 gives for it, compared
;; as a value; a row that raises answers `raised'.  A row marked OWN pins
;; goeteia's answer where R6RS leaves the matter open and Chez differs.
;;
;; Each `site' row answers (kind error? violation? i/o-read? message?
;; irritants?) for what the expression raises.
;;
;; ON THE TREE BEFORE THE CHANGE every one of these is a bare &error.
(import (rnrs))

(define-record-type point (fields x (mutable y)))
(define-record-type op (fields x) (opaque #t))
(define-record-type short (fields a b)
  (protocol (lambda (new) (lambda (a) (new a)))))
(define-enumeration colour (red green) colours)
(define-enumeration fruit (apple pear) fruits)
(define (rd s) (read (open-string-input-port s)))
;; the most specific of the types this file is about
(define (kind c)
  (cond ((not (condition? c)) 'not-a-condition)
        ((lexical-violation? c) 'lexical)
        ((assertion-violation? c) 'assertion)
        ((implementation-restriction-violation? c) 'implementation-restriction)
        ((i/o-file-does-not-exist-error? c) 'i/o-file-does-not-exist)
        ((i/o-filename-error? c) 'i/o-filename)
        ((i/o-error? c) 'i/o)
        ((violation? c) 'violation)
        ((error? c) 'error)
        (else 'other)))
;; (kind, an &error?, a &violation?, an &i/o-read?, has a message?, has
;; irritants?) of what the thunk raises
(define (site thunk)
  (guard (c (#t (list (kind c) (error? c) (violation? c) (i/o-read-error? c)
                      (message-condition? c) (irritants-condition? c))))
    (thunk)
    'no-condition))
(define (who-of thunk)
  (guard (c (#t (and (who-condition? c) (condition-who c)))) (thunk) 'no-condition))
(define (message-of thunk)
  (guard (c (#t (and (message-condition? c) (condition-message c)))) (thunk) 'no-condition))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 'record-type-name-of-a-non-descriptor
      (guard (c (#t 'raised))
        (site (lambda () (record-type-name 5))))
      '(assertion #f #t #f #t #t))
(want 'record-rtd-of-a-non-record
      (guard (c (#t 'raised))
        (site (lambda () (record-rtd 5))))
      '(assertion #f #t #f #t #t))
(want 'record-rtd-of-an-opaque-record
      (guard (c (#t 'raised))
        (site (lambda () (record-rtd (make-op 1)))))
      '(assertion #f #t #f #t #t))
(want 'accessor-on-a-stranger
      (guard (c (#t 'raised))
        (site (lambda () (point-x 5))))
      '(assertion #f #t #f #t #t))
(want 'mutator-on-a-stranger
      (guard (c (#t 'raised))
        (site (lambda () (point-y-set! 5 1))))
      '(assertion #f #t #f #t #t))
(want 'wrong-number-of-field-values
      (guard (c (#t 'raised))
        (site (lambda () (make-short 1))))
      '(assertion #f #t #f #t #t))
(want 'read-from-something-that-is-not-a-port
      (guard (c (#t 'raised))
        (site (lambda () (read 5))))
      '(assertion #f #t #f #t #t))
(want 'write-to-something-that-is-not-a-port
      (guard (c (#t 'raised))
        (site (lambda () (write 1 5))))
      '(assertion #f #t #f #t #t))
(want 'read-a-closing-parenthesis
      (guard (c (#t 'raised))
        (site (lambda () (rd ")"))))
      '(lexical #t #t #t #t #t))
(want 'read-an-unterminated-list
      (guard (c (#t 'raised))
        (site (lambda () (rd "(1 2"))))
      '(lexical #t #t #t #t #t))
(want 'read-an-unterminated-string
      (guard (c (#t 'raised))
        (site (lambda () (rd "\"abc"))))
      '(lexical #t #t #t #t #t))
(want 'read-an-unknown-character-name
      (guard (c (#t 'raised))
        (site (lambda () (rd "#\\nosuch"))))
      '(lexical #t #t #t #t #t))
(want 'read-a-lone-dot
      (guard (c (#t 'raised))
        (site (lambda () (rd "( . )"))))
      '(lexical #t #t #t #t #t))
(want 'read-an-unknown-hash-syntax
      (guard (c (#t 'raised))
        (site (lambda () (rd "#q"))))
      '(lexical #t #t #t #t #t))
(want 'read-a-malformed-number
      (guard (c (#t 'raised))
        (site (lambda () (rd "#e1.5.5"))))
      '(lexical #t #t #t #t #t))
(want 'a-reader-error-is-still-an-error
      (guard (c (#t 'raised))
        (guard (c ((error? c) 'caught-as-an-error)) (rd ")")))
      'caught-as-an-error)
(want 'hashtable-set-on-an-immutable-table
      (guard (c (#t 'raised))
        (site (lambda () (hashtable-set! (hashtable-copy (make-eq-hashtable)) 'a 1))))
      '(assertion #f #t #f #t #t))
(want 'shift-left-by-a-negative-count
      (guard (c (#t 'raised))
        (site (lambda () (bitwise-arithmetic-shift-left 1 -1))))
      '(assertion #f #t #f #t #t))
(want 'shift-right-by-a-negative-count
      (guard (c (#t 'raised))
        (site (lambda () (bitwise-arithmetic-shift-right 1 -1))))
      '(assertion #f #t #f #t #t))
;; OWN: Chez answers no-condition
(want 'shift-left-out-of-the-fixnum-range
      (guard (c (#t 'raised))
        (site (lambda () (bitwise-arithmetic-shift-left 1 100))))
      '(implementation-restriction #f #t #f #t #t))
(want 'div-by-zero
      (guard (c (#t 'raised))
        (site (lambda () (div 1 0))))
      '(assertion #f #t #f #t #t))
(want 'mod-by-zero
      (guard (c (#t 'raised))
        (site (lambda () (mod 1 0))))
      '(assertion #f #t #f #t #t))
(want 'div0-by-zero
      (guard (c (#t 'raised))
        (site (lambda () (div0 1 0))))
      '(assertion #f #t #f #t #t))
(want 'div-of-a-symbol
      (guard (c (#t 'raised))
        (site (lambda () (div 'a 2))))
      '(assertion #f #t #f #t #t))
;; OWN: Chez answers no-condition
(want 'div-of-a-flonum
      (guard (c (#t 'raised))
        (site (lambda () (div 1.5 2))))
      '(implementation-restriction #f #t #f #t #t))
(want 'quotient-of-a-bignum-by-zero
      (guard (c (#t 'raised))
        (site (lambda () (quotient 100000000000000000000 0))))
      '(assertion #f #t #f #t #t))
(want 'quotient-of-a-ratio
      (guard (c (#t 'raised))
        (site (lambda () (quotient 1/2 2))))
      '(assertion #f #t #f #t #t))
(want 'divide-by-zero
      (guard (c (#t 'raised))
        (site (lambda () (/ 1 0))))
      '(assertion #f #t #f #t #t))
(want 'less-than-on-a-complex-number
      (guard (c (#t 'raised))
        (site (lambda () (< 1+2i 3))))
      '(assertion #f #t #f #t #t))
(want 'exact-of-an-infinity
      (guard (c (#t 'raised))
        (site (lambda () (exact +inf.0))))
      '(assertion #f #t #f #t #t))
(want 'exact-of-a-nan
      (guard (c (#t 'raised))
        (site (lambda () (exact +nan.0))))
      '(assertion #f #t #f #t #t))
(want 'integer->char-of-a-surrogate
      (guard (c (#t 'raised))
        (site (lambda () (integer->char #xD800))))
      '(assertion #f #t #f #t #t))
(want 'integer->char-of-a-negative-number
      (guard (c (#t 'raised))
        (site (lambda () (integer->char -1))))
      '(assertion #f #t #f #t #t))
;; OWN: Chez answers (i/o-file-does-not-exist #t #f #f #t #t)
(want 'open-a-file-that-is-not-there
      (guard (c (#t 'raised))
        (site (lambda () (open-input-file "/nonexistent-dir-zz/x"))))
      '(i/o-filename #t #f #f #t #t))
(want 'the-path-is-in-the-condition
      (guard (c (#t 'raised))
        (guard (c (#t (and (i/o-filename-error? c) (i/o-error-filename c)))) (open-input-file "/nonexistent-dir-zz/x")))
      '"/nonexistent-dir-zz/x")
(want 'an-unknown-endianness
      (guard (c (#t 'raised))
        (site (lambda () (bytevector-u16-ref (make-bytevector 4 0) 0 'middle))))
      '(assertion #f #t #f #t #t))
(want 'a-length-that-is-not-a-multiple
      (guard (c (#t 'raised))
        (site (lambda () (bytevector->uint-list (make-bytevector 3 0) 'little 2))))
      '(assertion #f #t #f #t #t))
(want 'case-lambda-with-no-clause-for-the-count
      (guard (c (#t 'raised))
        (site (lambda () ((case-lambda ((a) a)) 1 2))))
      '(assertion #f #t #f #t #t))
(want 'enum-sets-of-two-types
      (guard (c (#t 'raised))
        (site (lambda () (enum-set-union (colours red) (fruits apple)))))
      '(assertion #f #t #f #t #t))
(want 'enum-set-constructor-on-a-stranger
      (guard (c (#t 'raised))
        (site (lambda () ((enum-set-constructor (colours red)) '(nosuch)))))
      '(assertion #f #t #f #t #t))
;; OWN: Chez answers (record-type-name record-rtd point-x #f read hashtable-set! bitwise-arithmetic-shift-left div / < exact integer->char open-input-file #f enum-set-union)
(want 'the-whos-do-not-change
      (guard (c (#t 'raised))
        (list (who-of (lambda () (record-type-name 5))) (who-of (lambda () (record-rtd 5))) (who-of (lambda () (point-x 5))) (who-of (lambda () (make-short 1))) (who-of (lambda () (rd ")"))) (who-of (lambda () (hashtable-set! (hashtable-copy (make-eq-hashtable)) 'a 1))) (who-of (lambda () (bitwise-arithmetic-shift-left 1 -1))) (who-of (lambda () (div 1 0))) (who-of (lambda () (/ 1 0))) (who-of (lambda () (< 1+2i 3))) (who-of (lambda () (exact +inf.0))) (who-of (lambda () (integer->char -1))) (who-of (lambda () (open-input-file "/nonexistent-dir-zz/x"))) (who-of (lambda () ((case-lambda ((a) a)) 1 2))) (who-of (lambda () (enum-set-union (colours red) (fruits apple))))))
      '(record-type-name record-rtd point-x define-record-type read hashtable-set! bitwise-arithmetic-shift-left div / < inexact->exact integer->char open-input-file case-lambda enum-set-union))
;; OWN: Chez answers ("~s is not of type ~s" "~? at char ~a of ~s" "undefined for ~s" "~s is not a valid unicode scalar value" "failed for ~a: ~(~a~)")
(want 'the-messages-do-not-change
      (guard (c (#t 'raised))
        (list (message-of (lambda () (point-x 5))) (message-of (lambda () (rd ")"))) (message-of (lambda () (div 1 0))) (message-of (lambda () (integer->char -1))) (message-of (lambda () (open-input-file "/nonexistent-dir-zz/x")))))
      '("not a record of this type" "unexpected ) at line 1 column 1" "division by zero" "not a Unicode scalar value" "cannot open"))

(display (if (null? fails) #t (reverse fails)))
