;; expect: (#t #t #t #t)
;; The macro-introduced top-level definitions that must work, and the
;; one that must not.
;;
;; THIS FILE IS CURRENTLY RED, and it is not a hygiene regression:
;; three of its four cells fail with the same defect as
;; defect-macro-toplevel-{var,const}-mark.ss and go green with them.
;; It stopped being a pure control the moment its procedure cases were
;; written so they actually reach the lookup -- see below.  The part
;; that is a control and must stay green throughout is the .mjs
;; beside it.
;;
;; THIS FILE WAS WRONG ON 2026-09-09 AND THE WAY IT WAS WRONG IS THE
;; POINT.  It carried a procedure case, `(define (mf y) (+ y 1))` called
;; from the same template, and asserted from its greenness that *fns*
;; was keyed and looked up consistently.  It is not.  That cell was
;; green because the body is a single expression under the inline cap,
;; so the INLINER erased the call before any table was consulted.  A
;; green control has to be shown to REACH what it claims to exercise;
;; this one never did, and a comment stating a mechanism was written on
;; the strength of it.
;;
;; -> The procedure cases below are chosen so the call survives to the
;; lookup, and each says why:
;;
;;   rec   self-recursive.  The durable one: no inliner fully
;;         inlines a self-call, so this keeps reaching the table even
;;         if the inline cap changes.
;;   letb  a `let` in the body, which inlinable-body? refuses today.
;;         That is a fact about the current inliner, so if this ever
;;         goes green while `rec` goes red, the inliner changed and
;;         this cell stopped testing anything.
;;   val   the name in a value position rather than an operator
;;         position, which goes through the reference path instead of
;;         the call path -- a different lookup, and it was broken too.
;;
;; The by-argument case is separate: a name handed in as a macro
;; ARGUMENT is never renamed, so the key and the lookup are the same
;; symbol.  If it goes red, the rule for marking macro arguments
;; changed.
;;
;; The refusal that must stay a refusal -- a user-written reference
;; to a name a macro introduced -- is a compile-time error and would
;; take these verdicts with it.  It is test/macro-toplevel-hygiene.mjs.
(import (rnrs))
(define-syntax by-argument (syntax-rules () ((_ n) (define n (car '(9))))))
(by-argument pin)

(define r1 #f) (define r2 #f) (define r3 #f)
(define-syntax in-template
  (syntax-rules ()
    ((_)
     (begin
       (define (rec n) (if (= n 0) 0 (+ 1 (rec (- n 1)))))
       (define (letb y) (let ((z (+ y 1))) (* z 2)))
       (define (val y) (+ y 1))
       (set! r1 (= 4 (rec 4)))
       (set! r2 (= 6 (letb 2)))
       (set! r3 (equal? '(2 3) (map val (list 1 2))))))))
(in-template)
(display (list (= 9 pin) r1 r2 r3))
