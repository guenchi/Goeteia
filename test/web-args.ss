;; expect: #t
;; (web args) where the host published nothing.
;;
;; run-tests.sh invokes the runners without a `--`, so this is the
;; zero-argument body -- the same one a browser page has, since a
;; page publishes no argv either.  That case is the one worth pinning
;; inside the suite: it must be zero arguments and an empty list, not
;; a raise and not one empty string.  Reaching for an argument that
;; is not there is the error, and it names itself.
;;
;; The non-empty side needs a runner invoked with arguments and lives
;; in test/args.mjs, which drives both CLIs.
(import (rnrs) (web args))

(define fails '())
(define (chk name ok)
  (unless ok
    (display "  FAIL ") (display name) (newline)
    (set! fails (cons name fails)))
  ok)

(define (raised-who thunk)
  (guard (e ((error? e) (condition-who e))
            (#t 'non-condition))
    (thunk)
    #f))

(define empty-ok
  (and
   (chk "a host that published nothing gives zero arguments"
        (= (args-count) 0))
   (chk "and an empty list" (null? (args-list)))
   (chk "and asking again gives the same answer"
        (and (= (args-count) 0) (null? (args-list))))))

(define range-ok
  (and
   (chk "the first argument of none names args-ref"
        (eq? (raised-who (lambda () (args-ref 0))) 'args-ref))
   (chk "a negative index names args-ref"
        (eq? (raised-who (lambda () (args-ref -1))) 'args-ref))
   (chk "a non-integer index names args-ref"
        (eq? (raised-who (lambda () (args-ref 'first))) 'args-ref))))

(and empty-ok range-ok (null? fails))
