;; expect: #t
;; The names of conditions and exceptions are EXPORTS of (rnrs): each can
;; be excluded from an import, and a program that excludes one may define
;; it (ledger R20f, R80).  The list is what Chez 10's (rnrs) takes from
;; (rnrs conditions) and (rnrs exceptions), its i/o and flonum condition
;; names, assertion-violation and syntax-violation -- 100 names with
;; condition-message, which is imported apart, under another name -- and
;; hashtable? and port?, which were bound before without being exports.
;;
;; A name the prelude binds outside the export table is visible in every
;; scope and cannot be excluded: the clause below is then refused ("names
;; an identifier its import set does not provide").
;;
;; The second half: the program's own definitions of excluded names do not
;; reach the machinery.  error still makes a condition that carries its
;; message, and guard still catches it, with the program's condition?,
;; make-message-condition, condition and with-exception-handler in scope.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: the clause is
;; refused.
(import (except (rnrs)
         &assertion &condition &error &i/o &i/o-decoding &i/o-encoding
         &i/o-file-already-exists &i/o-file-does-not-exist
         &i/o-file-is-read-only &i/o-file-protection &i/o-filename
         &i/o-invalid-position &i/o-port &i/o-read &i/o-write
         &implementation-restriction &irritants &lexical &message
         &no-infinities &no-nans &non-continuable &serious &syntax
         &undefined &violation &warning &who assertion-violation? condition
         condition-accessor condition-irritants condition-predicate
         condition-who condition? define-condition-type error?
         i/o-decoding-error? i/o-encoding-error-char i/o-encoding-error?
         i/o-error-filename i/o-error-port i/o-error-position i/o-error?
         i/o-file-already-exists-error? i/o-file-does-not-exist-error?
         i/o-file-is-read-only-error? i/o-file-protection-error?
         i/o-filename-error? i/o-invalid-position-error? i/o-port-error?
         i/o-read-error? i/o-write-error?
         implementation-restriction-violation? irritants-condition?
         lexical-violation? make-assertion-violation make-error
         make-i/o-decoding-error make-i/o-encoding-error make-i/o-error
         make-i/o-file-already-exists-error
         make-i/o-file-does-not-exist-error make-i/o-file-is-read-only-error
         make-i/o-file-protection-error make-i/o-filename-error
         make-i/o-invalid-position-error make-i/o-port-error
         make-i/o-read-error make-i/o-write-error
         make-implementation-restriction-violation make-irritants-condition
         make-lexical-violation make-message-condition
         make-no-infinities-violation make-no-nans-violation
         make-non-continuable-violation make-serious-condition
         make-syntax-violation make-undefined-violation make-violation
         make-warning make-who-condition message-condition?
         no-infinities-violation? no-nans-violation?
         non-continuable-violation? serious-condition? simple-conditions
         syntax-violation-form syntax-violation-subform syntax-violation?
         undefined-violation? violation? warning? who-condition?
         with-exception-handler assertion-violation syntax-violation
         hashtable? port?)
        (rename (only (rnrs) condition-message)
                (condition-message std-message)))

(define (condition? x) 'mine)
(define (error? x) 'mine)
(define (make-error) 'mine)
(define (make-message-condition m) 'mine)
(define (condition . cs) 'mine)
(define (message-condition? x) 'mine)
(define (with-exception-handler h t) 'mine)
(define (hashtable? x) 'mine)
(define (port? x) 'mine)

(define got
  (list (condition? 1) (error? 1) (make-error) (make-message-condition "m")
        (condition 1 2) (message-condition? 1) (with-exception-handler 1 2)
        (hashtable? 1) (port? 1)
        (guard (e (#t (std-message e))) (error 'f "the message" 1))
        (guard (e ((string? e) e)) (raise "s"))))

(display (if (equal? got '(mine mine mine mine mine mine mine mine mine
                           "the message" "s"))
             #t
             got))
