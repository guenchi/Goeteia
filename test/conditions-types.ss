;; expect: #t
;; the standard condition types of R6RS: every constructor against every
;; predicate, the accessors, compound conditions, define-condition-type,
;; condition-predicate and condition-accessor, conditions as records
;; (ledger R20f).
;;
;; Each row is an expression and the answer Chez 10 gives for it, compared
;; as a value; a row that raises answers `raised'.  A row marked OWN pins
;; goeteia's answer where R6RS leaves the matter open and Chez differs.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: the names are
;; unbound.
(import (rnrs))

;; every standard predicate, in one list: a row is one condition against all
(define preds
  (list message-condition? warning? serious-condition?
        error? violation? assertion-violation?
        irritants-condition? who-condition? non-continuable-violation?
        implementation-restriction-violation? lexical-violation? syntax-violation?
        undefined-violation? no-infinities-violation? no-nans-violation?
        i/o-error? i/o-read-error? i/o-write-error?
        i/o-invalid-position-error? i/o-filename-error? i/o-file-protection-error?
        i/o-file-is-read-only-error? i/o-file-already-exists-error? i/o-file-does-not-exist-error?
        i/o-port-error? i/o-decoding-error? i/o-encoding-error?))
(define (against c) (map (lambda (p) (p c)) preds))
(define (lineage c)
  (let up ((t (record-rtd c)) (acc '()))
    (if t (up (record-type-parent t) (cons (record-type-name t) acc)) (reverse acc))))
;; the program's own condition types
(define-condition-type &bare &condition make-bare bare?)
(define-condition-type &cost &error make-cost cost? (amount cost-amount))
(define-condition-type &trio &cost make-trio trio? (a trio-a) (b trio-b) (c trio-c))
(define m (make-message-condition "msg"))
(define w (make-who-condition 'me))
(define both (condition m w (make-error)))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 'is-message
      (guard (c (#t 'raised))
        (against (make-message-condition "m")))
      '(#t #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f))
(want 'is-warning
      (guard (c (#t 'raised))
        (against (make-warning)))
      '(#f #t #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f))
(want 'is-serious
      (guard (c (#t 'raised))
        (against (make-serious-condition)))
      '(#f #f #t #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f))
(want 'is-error
      (guard (c (#t 'raised))
        (against (make-error)))
      '(#f #f #t #t #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f))
(want 'is-violation
      (guard (c (#t 'raised))
        (against (make-violation)))
      '(#f #f #t #f #t #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f))
(want 'is-assertion
      (guard (c (#t 'raised))
        (against (make-assertion-violation)))
      '(#f #f #t #f #t #t #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f))
(want 'is-irritants
      (guard (c (#t 'raised))
        (against (make-irritants-condition '(1 2))))
      '(#f #f #f #f #f #f #t #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f))
(want 'is-who
      (guard (c (#t 'raised))
        (against (make-who-condition 'w)))
      '(#f #f #f #f #f #f #f #t #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f))
(want 'is-non-continuable
      (guard (c (#t 'raised))
        (against (make-non-continuable-violation)))
      '(#f #f #t #f #t #f #f #f #t #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f))
(want 'is-implementation-restriction
      (guard (c (#t 'raised))
        (against (make-implementation-restriction-violation)))
      '(#f #f #t #f #t #f #f #f #f #t #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f))
(want 'is-lexical
      (guard (c (#t 'raised))
        (against (make-lexical-violation)))
      '(#f #f #t #f #t #f #f #f #f #f #t #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f))
(want 'is-syntax
      (guard (c (#t 'raised))
        (against (make-syntax-violation 'form 'sub)))
      '(#f #f #t #f #t #f #f #f #f #f #f #t #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f))
(want 'is-undefined
      (guard (c (#t 'raised))
        (against (make-undefined-violation)))
      '(#f #f #t #f #t #f #f #f #f #f #f #f #t #f #f #f #f #f #f #f #f #f #f #f #f #f #f))
(want 'is-no-infinities
      (guard (c (#t 'raised))
        (against (make-no-infinities-violation)))
      '(#f #f #t #f #t #f #f #f #f #t #f #f #f #t #f #f #f #f #f #f #f #f #f #f #f #f #f))
(want 'is-no-nans
      (guard (c (#t 'raised))
        (against (make-no-nans-violation)))
      '(#f #f #t #f #t #f #f #f #f #t #f #f #f #f #t #f #f #f #f #f #f #f #f #f #f #f #f))
(want 'is-i-o
      (guard (c (#t 'raised))
        (against (make-i/o-error)))
      '(#f #f #t #t #f #f #f #f #f #f #f #f #f #f #f #t #f #f #f #f #f #f #f #f #f #f #f))
(want 'is-i-o-read
      (guard (c (#t 'raised))
        (against (make-i/o-read-error)))
      '(#f #f #t #t #f #f #f #f #f #f #f #f #f #f #f #t #t #f #f #f #f #f #f #f #f #f #f))
(want 'is-i-o-write
      (guard (c (#t 'raised))
        (against (make-i/o-write-error)))
      '(#f #f #t #t #f #f #f #f #f #f #f #f #f #f #f #t #f #t #f #f #f #f #f #f #f #f #f))
(want 'is-i-o-invalid-position
      (guard (c (#t 'raised))
        (against (make-i/o-invalid-position-error 7)))
      '(#f #f #t #t #f #f #f #f #f #f #f #f #f #f #f #t #f #f #t #f #f #f #f #f #f #f #f))
(want 'is-i-o-filename
      (guard (c (#t 'raised))
        (against (make-i/o-filename-error "f")))
      '(#f #f #t #t #f #f #f #f #f #f #f #f #f #f #f #t #f #f #f #t #f #f #f #f #f #f #f))
(want 'is-i-o-file-protection
      (guard (c (#t 'raised))
        (against (make-i/o-file-protection-error "f")))
      '(#f #f #t #t #f #f #f #f #f #f #f #f #f #f #f #t #f #f #f #t #t #f #f #f #f #f #f))
(want 'is-i-o-file-is-read-only
      (guard (c (#t 'raised))
        (against (make-i/o-file-is-read-only-error "f")))
      '(#f #f #t #t #f #f #f #f #f #f #f #f #f #f #f #t #f #f #f #t #t #t #f #f #f #f #f))
(want 'is-i-o-file-already-exists
      (guard (c (#t 'raised))
        (against (make-i/o-file-already-exists-error "f")))
      '(#f #f #t #t #f #f #f #f #f #f #f #f #f #f #f #t #f #f #f #t #f #f #t #f #f #f #f))
(want 'is-i-o-file-does-not-exist
      (guard (c (#t 'raised))
        (against (make-i/o-file-does-not-exist-error "f")))
      '(#f #f #t #t #f #f #f #f #f #f #f #f #f #f #f #t #f #f #f #t #f #f #f #t #f #f #f))
(want 'is-i-o-port
      (guard (c (#t 'raised))
        (against (make-i/o-port-error 'p)))
      '(#f #f #t #t #f #f #f #f #f #f #f #f #f #f #f #t #f #f #f #f #f #f #f #f #t #f #f))
(want 'is-i-o-decoding
      (guard (c (#t 'raised))
        (against (make-i/o-decoding-error 'p)))
      '(#f #f #t #t #f #f #f #f #f #f #f #f #f #f #f #t #f #f #f #f #f #f #f #f #t #t #f))
(want 'is-i-o-encoding
      (guard (c (#t 'raised))
        (against (make-i/o-encoding-error 'p #\x)))
      '(#f #f #t #t #f #f #f #f #f #f #f #f #f #f #f #t #f #f #f #f #f #f #f #f #t #f #t))
(want 'accessors
      (guard (c (#t 'raised))
        (list (condition-message (make-message-condition "m")) (condition-irritants (make-irritants-condition '(1 2))) (condition-who (make-who-condition 'w)) (syntax-violation-form (make-syntax-violation 'f 's)) (syntax-violation-subform (make-syntax-violation 'f 's)) (i/o-error-position (make-i/o-invalid-position-error 7)) (i/o-error-filename (make-i/o-file-does-not-exist-error "f")) (i/o-error-port (make-i/o-decoding-error 'p)) (i/o-encoding-error-char (make-i/o-encoding-error 'p #\x))))
      '("m" (1 2) w f s 7 "f" p #\x))
(want 'lineage
      (guard (c (#t 'raised))
        (map lineage (list (make-assertion-violation) (make-message-condition "m") (make-i/o-file-does-not-exist-error "f") (make-no-nans-violation) (make-trio 1 2 3 4))))
      '((&assertion &violation &serious &condition) (&message &condition) (&i/o-file-does-not-exist &i/o-filename &i/o &error &serious &condition) (&no-nans &implementation-restriction &violation &serious &condition) (&trio &cost &error &serious &condition)))
(want 'condition?
      (guard (c (#t 'raised))
        (list (condition? m) (condition? both) (condition? (condition)) (condition? 5) (condition? 'c) (condition? (list m)) (condition? (make-bare))))
      '(#t #t #t #f #f #f #t))
(want 'simple-conditions
      (guard (c (#t 'raised))
        (list (map lineage (simple-conditions both)) (length (simple-conditions m)) (eq? (car (simple-conditions m)) m) (simple-conditions (condition))))
      '(((&message &condition) (&who &condition) (&error &serious &condition)) 1 #t ()))
(want 'one-component-is-itself
      (guard (c (#t 'raised))
        (list (eq? (condition m) m) (eq? (condition (condition) m) m) (eq? (condition (condition m)) m)))
      '(#t #t #t))
(want 'flattening
      (guard (c (#t 'raised))
        (map lineage (simple-conditions (condition (condition m w) (condition) (condition (make-error) (condition (make-warning)))))))
      '((&message &condition) (&who &condition) (&error &serious &condition) (&warning &condition)))
(want 'compound-against-predicates
      (guard (c (#t 'raised))
        (against (condition (make-assertion-violation) (make-who-condition 'f) (make-message-condition "bad") (make-irritants-condition '(9)))))
      '(#t #f #t #f #t #t #t #t #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f))
(want 'accessors-on-a-compound
      (guard (c (#t 'raised))
        (let ((c (condition (make-assertion-violation) (make-who-condition 'f) (make-message-condition "bad") (make-irritants-condition '(9))))) (list (condition-who c) (condition-message c) (condition-irritants c))))
      '(f "bad" (9)))
(want 'first-of-two-components
      (guard (c (#t 'raised))
        (let ((c (condition (make-message-condition "first") (make-who-condition 'a) (make-message-condition "second") (make-who-condition 'b)))) (list (condition-message c) (condition-who c))))
      '("first" a))
(want 'accessor-finds-a-descendant
      (guard (c (#t 'raised))
        (list (cost-amount (make-trio 10 1 2 3)) (cost-amount (condition (make-warning) (make-trio 11 1 2 3))) (trio-b (condition m (make-trio 12 1 2 3)))))
      '(10 11 2))
(want 'user-types
      (guard (c (#t 'raised))
        (list (bare? (make-bare)) (bare? m) (cost? (make-cost 5)) (error? (make-cost 5)) (serious-condition? (make-cost 5)) (cost-amount (make-cost 5)) (trio? (make-trio 1 2 3 4)) (cost? (make-trio 1 2 3 4)) (list (cost-amount (make-trio 1 2 3 4)) (trio-a (make-trio 1 2 3 4)) (trio-b (make-trio 1 2 3 4)) (trio-c (make-trio 1 2 3 4))) (trio? (make-cost 5))))
      '(#t #f #t #t #t 5 #t #t (1 2 3 4) #f))
(want 'condition-predicate-and-accessor
      (guard (c (#t 'raised))
        (let ((p (condition-predicate (record-type-descriptor &cost))) (a (condition-accessor (record-type-descriptor &cost) cost-amount)) (pm (condition-predicate (record-type-descriptor &message)))) (list (p (make-cost 1)) (p (make-trio 2 0 0 0)) (p m) (p (condition m (make-cost 3))) (a (make-cost 4)) (a (condition m (make-trio 5 0 0 0))) (pm both) (pm (make-cost 1)) (p 7))))
      '(#t #t #f #t 4 5 #t #f #f))
(want 'accessor-without-its-component
      (guard (c (#t 'raised))
        (list (guard (c ((assertion-violation? c) 'assertion) (#t 'other)) (condition-message (make-warning))) (guard (c ((assertion-violation? c) 'assertion) (#t 'other)) (condition-who (condition m (make-error)))) (guard (c ((assertion-violation? c) 'assertion) (#t 'other)) (cost-amount m)) (guard (c ((assertion-violation? c) 'assertion) (#t 'other)) (condition-message 5))))
      '(assertion assertion assertion assertion))
(want 'simple-conditions-are-records
      (guard (c (#t 'raised))
        (list (record? m) (record? (make-cost 1)) (eq? (record-rtd (make-cost 1)) (record-type-descriptor &cost)) (eq? (record-type-parent (record-type-descriptor &cost)) (record-type-descriptor &error)) (record-type-name (record-type-descriptor &condition)) (record-type-parent (record-type-descriptor &condition))))
      '(#t #t #t #t &condition #f))
;; OWN: Chez answers #t
(want 'a-compound-is-not-a-record
      (guard (c (#t 'raised))
        (record? both))
      '#f)

(display (if (null? fails) #t (reverse fails)))
