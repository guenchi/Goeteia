;; expect: 536870911.0|536870912.0|536870913.0|1000000000000.0|1700000000000.0|9007199254740992.0|-1700000000000.0|-536870913.0|<big-flonum>|-<big-flonum>|+nan.0|0.5|1.0|536870911.5|0.25|100.0|-0.5|0.0
;; The printer's integer part used to go through %fl->fx, which is an
;; i31 fixnum and stops at 2^29-1 = 536870911.  Past that it printed the
;; placeholder "<big-flonum>" -- and returned successfully, so a caller
;; that formatted a millisecond timestamp (~1.7e12) got that text with
;; no error anywhere.  Through (web json) it produced {"t":<big-flonum>},
;; which is not JSON and which no parser will read back.
;;
;; This file is the printer's own boundary, not JSON's: the defect
;; belongs to display, and JSON is one of its callers.  One .ss covers
;; both targets, because run-tests.sh compiles every test to wasm AND
;; to JS and holds both to this line -- the two backends have separate
;; number representations, so "prints the same on both" is not free.
;;
;; The last seven values are a CHARACTERISATION half: they never went
;; near the fixnum cap and their output must not move.  Without them a
;; repair that reroutes everything through the new path would look
;; correct.
(define (p x) (display x) (display "|"))
(define inf (fl/ 1.0 0.0))
(p 536870911.0)                       ; the last one that printed
(p 536870912.0)                       ; 2^29 -- the first that did not
(p 536870913.0)
(p 1000000000000.0)
(p 1700000000000.0)                   ; a millisecond timestamp
(p 9007199254740992.0)                ; 2^53, where doubles stop being
                                      ; able to count by one
(p (fl- 0.0 1700000000000.0))         ; the sign survives the new path
(p (fl- 0.0 536870913.0))
(p inf)                               ; infinity has no digits: it keeps
(p (fl- 0.0 inf))                     ; the placeholder it always had
(p (fl/ 0.0 0.0))                     ; nan is answered before this code
(p 0.5)
(p 1.0)
(p 536870911.5)                       ; a fraction just under the cap
(p 0.25)
(p 100.0)
(p (fl- 0.0 0.5))
(display 0.0)
(newline)
