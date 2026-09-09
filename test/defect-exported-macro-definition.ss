;; expect: #t
;; RED ON PURPOSE, and NOT one of the 2026-09-06 findings: a library
;; can export a name a macro defined, and an importer cannot call it.
;;
;;     unhandled exception: cannot call: made-by-macro
;;
;; The export list is unmarked when the program is prepared, and the
;; procedure table is keyed by the identifier as registered -- which
;; carries the expansion's mark.  ⇒ The export path asks with the bare
;; name and the table answers about a marked one, which is the same
;; mismatch that made a macro's own expansion unable to see its own
;; definitions, at the one place that was not repaired with the rest.
;;
;; ⭐ This was reported as a hypothesis by the session doing that
;; repair, explicitly without a claim that it was reachable.  It is:
;; the file beside this one is the library, and this program is the
;; importer.
;;
;; ⚠️ A name is not required to be spelled out to be exported.  A macro
;; that defines a family of accessors, a table-driven set of
;; constructors, anything generated -- all of it exports by writing the
;; name in the export list and letting the macro produce the
;; definition, which is the ordinary reason to have the macro.
;;
;; The control is the hand-written export beside it in the same
;; library.  If both go red the library did not load at all, which is a
;; different problem and this cell should not be read as this defect.
(import (rnrs) (probe exported-macro))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

(want 'CONTROL-hand-written-export (written-out 2) 4)
(want 'exported-macro-definition (made-by-macro 2) 3)

(if (null? fails) (display #t) (begin (display fails) (newline)))
