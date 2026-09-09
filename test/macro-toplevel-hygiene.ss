;; expect: (#t #t)
;; The macro-introduced top-level definitions that DO work, and why
;; each one works -- the green side of the two defect files beside it.
;;
;; ⭐ A pair of reds without these is satisfied by a fix that stops
;; renaming macro-introduced names at all, which would be a much worse
;; compiler.  These say what the fix must leave alone.
;;
;;   1. A name handed in as a macro ARGUMENT is never renamed, so the
;;      key *vars* is built from and the key the lookup uses are the
;;      same one.  ⇒ If this goes red, the rule for marking a macro's
;;      arguments changed.
;;
;;   2. A PROCEDURE definition introduced by a template, called from
;;      that same template.  *fns* is keyed and looked up consistently,
;;      so this has always worked -- and it is the exact counterpart of
;;      the two red files, differing only in which table holds the
;;      name.  ⭐ That is what localises the defect: it is not "macros
;;      and top-level definitions", it is *vars* specifically.
;;
;; ⚠️ A third file used to sit beside the two reds asserting that this
;; procedure case was broken.  It was not; measured 2026-09-09.  Its
;; row is not gone, it moved here, which is the only way a cell may be
;; removed -- by naming who took over.
;;
;; ⛔ The refusal that must stay a refusal -- a user-written reference
;; to a name a macro introduced -- cannot live in this file, because it
;; is a compile-time error and would take these two verdicts with it.
;; It is test/macro-toplevel-hygiene.mjs.
(import (rnrs))
(define-syntax by-argument (syntax-rules () ((_ n) (define n (car '(9))))))
(by-argument pin)
(define-syntax in-template
  (syntax-rules ()
    ((_) (begin (define (mf y) (+ y 1))
                (set! seen (= 3 (mf 2)))))))
(define seen #f)
(in-template)
(display (list (= 9 pin) seen))
