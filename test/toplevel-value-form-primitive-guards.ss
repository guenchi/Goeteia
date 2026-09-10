;; expect: (mine mine mine 99.0 99.0 99 99)
;; The value-form twin of macro-toplevel-primitive-guards: the same
;; seven positions, every name excluded from (rnrs) and then defined
;; as a VALUE rather than as a function.  Each emission site that
;; recognises a primitive by its name used to ask only whether a
;; top-level FUNCTION shadowed it, so these definitions were invisible
;; there; they now ask one predicate that sees variables too.  The
;; definitions answer #f or a constant where the primitive answers
;; otherwise, because a fixture discriminates only when the two
;; candidates disagree -- an earlier draft answered a truthy symbol and
;; could not tell them apart in test position.
;;
;; The output names the guard that broke: with the =/< fast path
;; reverted the second element reads builtin, with the fl<? fast path
;; the third, with the i32-predicate path the first, with the
;; primitive arm of compile-app all of them and 3.0 3.0 8 8.
(import (except (rnrs) zero? fl+ fl* fl<? bitwise-and <))
(define zero? (lambda (x) #f))
(define fl+ (lambda (a b) 99.0))
(define fl* (lambda (a b) 99.0))
(define fl<? (lambda (a b) #f))
(define bitwise-and (lambda (a b) 99))
(define < (lambda (a b) #f))
(display (list (if (zero? 0) (quote builtin) (quote mine))
               (if (< 1 2) (quote builtin) (quote mine))
               (if (fl<? 1.0 2.0) (quote builtin) (quote mine))
               (fl+ 1.0 2.0)
               (fl* (fl+ 1.0 2.0) 1.0)
               (bitwise-and 12 10)
               (bitwise-and (bitwise-and 12 10) 255)))
