;; expect: #t
;; sealed, opaque and nongenerative record types, and the inspection
;; procedures (record?, record-rtd, record-type-name and the rest).
;;
;; Each row is an expression and the answer Chez 10 gives for it, compared
;; as a value; a row that raises answers `raised'.  A row marked OWN pins
;; goeteia's answer where R6RS leaves the matter open and Chez differs.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile, or its rows are
;; red: every clause but `fields' was ignored.
(import (rnrs))

(define-record-type point (fields x y))
(define-record-type point3 (parent point) (fields z))
(define-record-type vault (fields secret) (opaque #t))
(define-record-type inner-vault (parent vault) (fields more))
(define-record-type final (fields v) (sealed #t))
(define-record-type open-flags (fields v) (sealed #f) (opaque #f))
(define-record-type stamp (fields n) (nongenerative stamp-7f3a))
(define-record-type (stamp2 make-stamp2 stamp2?) (fields (immutable n stamp2-n))
  (nongenerative stamp-7f3a))
(define-record-type stamp-child (parent stamp2) (fields m))
(define-record-type anon (fields a) (nongenerative))
(define p (make-point 1 2))
(define p3 (make-point3 1 2 3))
(define (rtd-facts t)
  (list (record-type-name t) (record-type-sealed? t) (record-type-opaque? t)
        (record-type-generative? t)))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 'record?
      (guard (c (#t 'raised))
        (list (record? p) (record? p3) (record? (make-final 1)) (record? (make-stamp 1)) (record? 5) (record? "s") (record? (vector 1)) (record? car) (record? '(1)) (record? 1.5) (record? 1000000000000000000000000000000)))
      '(#t #t #t #t #f #f #f #f #f #f #f))
(want 'opaque-is-not-a-record
      (guard (c (#t 'raised))
        (list (record? (make-vault 1)) (record? (make-inner-vault 1 2)) (vault? (make-inner-vault 1 2)) (vault-secret (make-inner-vault 1 2)) (inner-vault-more (make-inner-vault 1 2))))
      '(#f #f #t 1 2))
(want 'record-rtd
      (guard (c (#t 'raised))
        (list (eq? (record-rtd p) (record-type-descriptor point)) (eq? (record-rtd p3) (record-type-descriptor point3)) (eq? (record-rtd p3) (record-type-descriptor point))))
      '(#t #t #f))
(want 'raises-record-rtd-of-opaque
      (guard (c (#t 'raised))
        (record-rtd (make-vault 1)))
      'raised)
(want 'raises-record-rtd-of-a-number
      (guard (c (#t 'raised))
        (record-rtd 5))
      'raised)
(want 'descriptor-facts
      (guard (c (#t 'raised))
        (map rtd-facts (list (record-type-descriptor point) (record-type-descriptor point3) (record-type-descriptor vault) (record-type-descriptor inner-vault) (record-type-descriptor final) (record-type-descriptor open-flags) (record-type-descriptor stamp) (record-type-descriptor anon))))
      '((point #f #f #t) (point3 #f #f #t) (vault #f #t #t) (inner-vault #f #t #t) (final #t #f #t) (open-flags #f #f #t) (stamp #f #f #f) (anon #f #f #f)))
(want 'parents
      (guard (c (#t 'raised))
        (list (eq? (record-type-parent (record-type-descriptor point3)) (record-type-descriptor point)) (record-type-parent (record-type-descriptor point)) (eq? (record-type-parent (record-type-descriptor inner-vault)) (record-type-descriptor vault))))
      '(#t #f #t))
(want 'descriptor?
      (guard (c (#t 'raised))
        (list (record-type-descriptor? (record-type-descriptor point)) (record-type-descriptor? p) (record-type-descriptor? 5) (record-type-descriptor? 'point) (record-type-descriptor? '(point))))
      '(#t #f #f #f #f))
(want 'uid
      (guard (c (#t 'raised))
        (list (record-type-uid (record-type-descriptor stamp)) (symbol? (record-type-uid (record-type-descriptor anon)))))
      '(stamp-7f3a #t))
(want 'one-uid-one-type
      (guard (c (#t 'raised))
        (let ((a (make-stamp 1)) (b (make-stamp2 2))) (list (stamp? b) (stamp2? a) (stamp-n b) (stamp2-n a) (eq? (record-type-descriptor stamp) (record-type-descriptor stamp2)) (eq? (record-rtd a) (record-rtd b)))))
      '(#t #t 2 1 #t #t))
(want 'child-of-the-second-name
      (guard (c (#t 'raised))
        (let ((c (make-stamp-child 1 2))) (list (stamp? c) (stamp2? c) (stamp-child? c) (stamp-n c) (stamp2-n c) (stamp-child-m c) (stamp-child? (make-stamp 1)))))
      '(#t #t #t 1 1 2 #f))
(want 'record-predicate
      (guard (c (#t 'raised))
        (let ((pt? (record-predicate (record-type-descriptor point)))) (list (pt? p) (pt? p3) (pt? 5) (pt? (make-final 1)) (pt? (record-type-descriptor point)))))
      '(#t #t #f #f #f))
(want 'predicates-on-a-descriptor
      (guard (c (#t 'raised))
        (let ((t (record-type-descriptor point))) (list (point? t) (point3? t) (vault? t) (final? t) (stamp? t))))
      '(#f #f #f #f #f))
;; OWN: Chez answers #t
(want 'record?-of-a-descriptor
      (guard (c (#t 'raised))
        (record? (record-type-descriptor point)))
      '#f)
;; OWN: Chez answers (#t #f)
(want 'the-preludes-own-types
      (guard (c (#t 'raised))
        (list (record? (make-eq-hashtable)) (record? (current-output-port))))
      '(#f #f))
(want 'as-hashtable-keys
      (guard (c (#t 'raised))
        (let ((h (make-eqv-hashtable)) (t (record-type-descriptor point))) (hashtable-set! h t 'rtd) (hashtable-set! h p 'rec) (hashtable-set! h p3 'rec3) (list (hashtable-ref h t #f) (hashtable-ref h p #f) (hashtable-ref h p3 #f) (hashtable-ref h (record-type-descriptor point3) #f) (equal? t t) (equal? t (record-type-descriptor point3)))))
      '(rtd rec rec3 #f #t #f))
(want 'printing-does-not-fail
      (guard (c (#t 'raised))
        (string? (call-with-string-output-port (lambda (o) (display p o) (write p3 o) (display (record-type-descriptor point) o) (write (record-type-descriptor point3) o)))))
      '#t)
(want 'sealed-still-works
      (guard (c (#t 'raised))
        (let ((f (make-final 9))) (list (final? f) (final-v f) (final? p))))
      '(#t 9 #f))

(display (if (null? fails) #t (reverse fails)))
