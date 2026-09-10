;; expect: #t
;; What a callback may return, and what the host is told when it
;; returns something else.
;;
;; A callback's raise cannot cross back into the host: (web js) answers
;; undefined so the host's loop stays alive, and reports through a
;; replaceable hook so the failure is not silent.  Two properties hold
;; that arrangement up, and until now neither was pinned.
;;
;; THE UNSPECIFIED VALUE IS A VALUE.  A callback that ends in a side
;; effect returns it, which is what an event handler normally does --
;; onclick, requestAnimationFrame, an effect body.  ->js had no branch
;; for it, so every such call reported, and a stored round carried
;; FIFTY-ONE reports while every test involved passed.  They were
;; invisible because they went to stderr and the runner compared stdout.
;;
;; AND THE DIAGNOSIS SURVIVES.  Silencing the noise by widening ->js
;; to accept anything would have been the obvious repair and the wrong
;; one: a callback that returns a pair is a mistake, and it must still
;; say so, by type.  Without this half, deleting the else branch
;; passes everything above.
;;
;; The hook is installed here rather than letting the report reach the
;; console, for a reason worth stating: the runner now FAILS any test
;; that reports a callback error, so a cell that must provoke one cannot
;; let it out.  It is captured and asserted on instead.
(import (rnrs) (web js))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))

(define seen '())
(js-callback-error!
 (lambda (e)
   (set! seen (cons (if (and (error? e) (string? (condition-message e)))
                        (condition-message e)
                        "non-error")
                    seen))))
(define (reports thunk)                 ; -> the message, or #f
  (set! seen '())
  (js-set! (js-global) "__probe" thunk)
  (js-eval "globalThis.__probe()")
  (if (null? seen) #f (car seen)))
(define (has-sub? hay needle)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? (substring hay i (+ i n)) needle) #t)
            (else (loop (+ i 1)))))))

;; ---- the values a callback may return ----
(check "a number is fine" (not (reports (lambda _ 42))))
(check "a string is fine" (not (reports (lambda _ "x"))))
(check "a boolean is fine" (not (reports (lambda _ #t))))
(check "js-undefined is fine" (not (reports (lambda _ (js-undefined)))))
;; the one this file exists for, in four spellings that are all the
;; same object -- so the cell does not depend on how the library happens
;; to construct it
(define box (vector 0))
(check "a callback ending in set! reports nothing"
       (not (reports (lambda _ (vector-set! box 0 1)))))
(check "a callback ending in for-each reports nothing"
       (not (reports (lambda _ (for-each (lambda (x) x) '(1 2))))))
(check "a callback ending in a false when reports nothing"
       (not (reports (lambda _ (when #f 1)))))
(check "and the unspecified value written directly reports nothing"
       (not (reports (lambda _ (if #f #f)))))

;; ---- and what must still be refused, by type ----
;; A repair that widened ->js to accept anything would pass every
;; line above.  This is the line that says the diagnosis survived.
(let ((m (reports (lambda _ (cons 1 2)))))
  (check "a callback returning a pair still reports" (string? m))
  (check "and the report names the type, so a residual one is diagnosable"
         (and (string? m) (has-sub? m "pair"))))
(let ((m (reports (lambda _ (vector 1 2)))))
  (check "a vector too, named" (and (string? m) (has-sub? m "vector"))))
(display (= failed 0))
