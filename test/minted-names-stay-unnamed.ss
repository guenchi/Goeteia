;; expect: #t
;; A name the compiler mints for its own use -- with gensym, so that no
;; program can write it -- never reaches the program as a symbol.  A minted
;; name that ends up in a quoted datum (a record accessor's who, say) is
;; emitted as a symbol constant with the minted name's printed form, and
;; the runtime then holds two symbols of one name: the program's own 'raw
;; is no longer (string->symbol "raw").  The printed form is the host's,
;; too ("raw" under Chez, "raw164" under the self-hosted compiler), so the
;; two compilers' products differ.
;;
;; The program below uses everything that mints names -- a record type with
;; a parent and a protocol, a nongenerative one, a condition type of its
;; own, guard, with-exception-handler, the standard condition accessors --
;; and then asks, for every base name the compiler hands to gensym, whether
;; the program's own symbol of that name is the interned one.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile
;; (define-condition-type is unbound).  On the first candidate of the
;; conditions batch it answered #f on both targets.
(import (rnrs))

(define-record-type point (fields x y))
(define-record-type cpoint (parent point) (fields c)
  (protocol (lambda (n) (lambda (x y c) ((n x y) c)))))
(define-record-type tagged (fields v) (nongenerative))
(define-condition-type &cost &error make-cost cost? (amount cost-amount))

(define got
  (list (cpoint-c (make-cpoint 1 2 3))
        (tagged-v (make-tagged 4))
        (guard (e ((cost? e) (cost-amount e))) (raise (make-cost 5)))
        (guard (e ((message-condition? e) (condition-message e)))
          (error 'f "m"))
        (guard (e ((who-condition? e) (condition-who e)))
          (assertion-violation 'g "m" 1))
        (guard (e ((irritants-condition? e) (condition-irritants e)))
          (error 'h "m" 7))
        (with-exception-handler (lambda (c) 6)
          (lambda () (raise-continuable 'c)))))

(define interned
  (list
        (eq? 'raw (string->symbol "raw"))
        (eq? 'is-a (string->symbol "is-a"))
        (eq? 'x (string->symbol "x"))
        (eq? 'rtd (string->symbol "rtd"))
        (eq? 'cd (string->symbol "cd"))
        (eq? 'f (string->symbol "f"))
        (eq? 't (string->symbol "t"))
        (eq? 'v (string->symbol "v"))
        (eq? 'p (string->symbol "p"))
        (eq? 'l (string->symbol "l"))
        (eq? 'a (string->symbol "a"))
        (eq? 'acc (string->symbol "acc"))
        (eq? 'args (string->symbol "args"))
        (eq? 'lp (string->symbol "lp"))
        (eq? 'loop (string->symbol "loop"))
        (eq? 'rest (string->symbol "rest"))
        (eq? 'stx (string->symbol "stx"))
        (eq? 'kwind (string->symbol "kwind"))
        (eq? 'ktok (string->symbol "ktok"))
        (eq? 'written-name (string->symbol "written-name"))))

(display
 (cond ((not (equal? got '(3 4 5 "m" g (7) 6))) got)
       ((not (for-all (lambda (b) b) interned)) interned)
       (else #t)))
