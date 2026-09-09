;; expect: (mine 99.0 99 mine)
;; The primitive guards and the dispatcher must read the top-level
;; tables the same way.
;;
;; ⭐ THIS CELL IS THE ONLY EVIDENCE FOR ONE THING: that a place asking
;; "is this name a primitive?" resolves it exactly as the place that
;; then compiles the call.  Six guards consult those tables besides the
;; dispatcher, and if any of them keeps the old lookup while the tables
;; are keyed the new way, that guard answers "primitive" for a name the
;; dispatcher has a definition for.  ⚠️ Nothing else in the suite
;; notices: the program still compiles, still runs, and quietly calls
;; the built-in instead of the definition in front of it.
;;
;; Each position below is a different guard, and the answer says which
;; one spoke:
;;
;;   zero?         the i32 predicate path in compile-test
;;   fl+           a float context
;;   bitwise-and   an i32 context
;;   <             the =/< path in compile-test
;;
;; `mine` / 99.0 / 99 mean the definition won; `builtin` / 3.0 / 8 mean
;; the guard did.
;;
;; The expected line is what Chez answers for this same file, not
;; what this implementation was reasoned to owe.  Measured at HEAD
;; before the fix, it answers (builtin 3.0 8 builtin).
;;
;; ⭐ EVERY DEFINITION HERE IS SELF-RECURSIVE ON A BRANCH THAT NEVER
;; RUNS, and that is not decoration.  A one-expression body is under
;; the inline cap, and the inliner erases the call before any table is
;; consulted -- which is exactly how an earlier control in this
;; directory came out green while testing nothing at all.  The `(eq? x
;; 'never)` arm is what keeps each call alive long enough to be
;; dispatched.
;;
;; ⚠️ This is NOT the C02 shadowing case.  These names are introduced
;; by a macro and referenced from the same template, so they carry the
;; same marks and must meet.  A top-level definition the USER wrote
;; shadowing a primitive is a separate, still-open finding with its own
;; red cell, and neither result implies the other.
(import (rnrs))
(define-syntax m
  (syntax-rules ()
    ((_)
     (begin
       (define (zero? x) (if (eq? x 'never) (zero? x) #f))
       (define (fl+ a b) (if (eq? a 'never) (fl+ a b) 99.0))
       (define (bitwise-and a b) (if (eq? a 'never) (bitwise-and a b) 99))
       (define (< a b) (if (eq? a 'never) (< a b) #f))
       (display (list (if (zero? 0) 'builtin 'mine)
                      (fl+ 1.0 2.0)
                      (bitwise-and 12 10)
                      (if (< 1 2) 'builtin 'mine)))))))
(m)
