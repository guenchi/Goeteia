;; expect: #t
;; (gam state): state-send! is documented as raising where
;; state-transition! declines, and does not.
;;
;; lib/gam/state.ss says of state-transition!:
;;
;;     Answers whether it went, rather than raising when it did not.
;;     This is the one place that differs from state-send!
;;
;; A reader takes from that: send! is the one that shouts, transition!
;; is the one for an event the caller did not choose.  That is the
;; distinction the two procedures exist to draw.
;;
;; It does not hold for any machine make-state-machine builds.  Whether
;; an unknown event raises is decided by an `on-unknown' clause in the
;; spec, the shorthand emits no such clause, and the default is to
;; answer no actions and stay put.  So a caller that sends an event it
;; chose -- one its own code decided was the right thing to do -- gets
;; silence and a machine that did not move.
;;
;; The symptom is the worst kind: not a wrong state, but a state that
;; did not change, surfacing later as a thing that "sometimes doesn't
;; work".
;;
;; The behaviour the comment describes is the right one and the
;; shorthand is what should change: an event a caller chose and that
;; cannot happen is a fault in the caller, and state-transition! is
;; already there for the other case.  A machine assembled from a raw
;; spec keeps deciding for itself, since make-event-state-machine takes
;; the clause from the caller.
(import (rnrs) (gam state))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (raises? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))

(define (door) (make-state-machine 'shut '((shut open) (open shut locked)
                                           (locked open))))

;; CONTROL: an event that IS available must still go through quietly.
;; Without this the row below is satisfied by a machine that refuses
;; everything.
(let ((s (door)))
  (want 's01-CONTROL-an-available-event-is-sent
        (raises? (lambda () (state-send! s 'open))) #f)
  (want 's01-CONTROL-and-it-moved (state-current s) 'open))

;; CONTROL: state-transition! keeps declining rather than raising.  The
;; fix must not turn both of them into the same procedure.
(let ((s (door)))
  (want 's01-CONTROL-transition-still-declines
        (state-transition! s 'locked) #f)
  (want 's01-CONTROL-and-left-it-alone (state-current s) 'shut))

;; THE DEFECT: sending an impossible event answers nothing and moves
;; nothing, where the documented behaviour is to raise.
(let ((s (door)))
  (want 's01-send-of-an-impossible-event-raises
        (raises? (lambda () (state-send! s 'locked))) #t))

;; And the same for an event that is in no transition at all, which is
;; the likelier spelling of the mistake -- a typo in an event name.
(let ((s (door)))
  (want 's01-send-of-an-unknown-event-raises
        (raises? (lambda () (state-send! s 'unlokc))) #t))

;; A machine given the clause explicitly already behaves this way, so
;; the mechanism is present and only the shorthand does not use it.
;; This row is GREEN today and is here to say where the fix goes.
(let ((s (make-event-state-machine
           (list (list 'states '(a b)) (list 'initial 'a)
                 (list 'transitions '((a go b)))
                 (list 'on-unknown 'error))
           '())))
  (want 's01-the-mechanism-exists-and-works
        (raises? (lambda () (state-send! s 'nope))) #t))

(display (if (null? fails) #t (reverse fails)))
