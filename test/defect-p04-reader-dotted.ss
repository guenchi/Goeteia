;; expect: #t
;; REGRESSION GUARD (written as a red witness at faa808c; green since).
;; The defect as it then was: the prelude's reader accepts a dotted tail
;; with more than one item after the dot, and SILENTLY DROPS the rest.
;;
;;   (1 . 2 3)    reads as (1 . 2)   -- the 3 is gone
;;   (1 . 2 . 3)  reads as (1 . 2)   -- ". 3" is gone
;;   (. 2)        reads as 2         -- the dot is swallowed
;;
;; Not an error: a program that reads data this way gets a shorter
;; answer than the text it was given, with nothing said.  Chez refuses
;; all three ("more than one item found after dot", "unexpected dot").
;;
;; There are TWO readers in this tree and only one of them is wrong.
;; This is the prelude's `read`, the one a compiled program calls.  The
;; host-side driver's reader refuses these correctly, and the driver
;; has the opposite defect on block comments -- see
;; test/defect-r02-driver-block-comment.mjs.  -> Neither file's result
;; can be assumed from the other; the two were measured separately, and
;; the earlier attempt to measure this one through `(quote ...)` in a
;; source file was reading the HOST's reader and learned nothing about
;; this one.
;;
;; The controls are the well-formed dotted shapes, and (1 . ) which the
;; reader already refuses: a fix that rejected every dot would satisfy
;; the reds and break real programs.
(import (rnrs))
(define (try s) (guard (e (#t 'REFUSED))
                  (with-input-from-string s (lambda () (list 'READ (read))))))
(define fails '())
(define (want s expect)
  (let ((got (try s)))
    (unless (equal? got expect)
      (set! fails (cons (list s 'got got 'want expect) fails)))))

;; reds -- each of these must become a refusal
(want "(1 . 2 3)"   'REFUSED)
(want "(1 . 2 . 3)" 'REFUSED)
(want "(. 2)"       'REFUSED)
;; already-correct refusals, kept so a fix does not lose them
(want "(1 . )"      'REFUSED)
(want "(1 .)"       'REFUSED)
;; controls: the shapes that must keep working
(want "(1 . 2)"     '(READ (1 . 2)))
(want "(1 2 . 3)"   '(READ (1 2 . 3)))
(want "(a . b)"     '(READ (a . b)))
(want "(1 2 3)"     '(READ (1 2 3)))

(if (null? fails) (display #t) (begin (display fails) (newline)))
