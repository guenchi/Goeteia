;; expect: #t
;; What this cell is the only evidence for: (gam state) is a cell
;; holding a machine, and the round trip through a datum carries the
;; spec but NOT the procedures the spec names.
;;
;; That asymmetry is the part a reader assumes wrongly.  A saved
;; machine looks complete -- it names its actions -- and loading it
;; with the wrong bindings, or none, is refused rather than silently
;; producing a machine whose transitions do nothing.
(import (rnrs) (gam state) (lng machine))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (raises? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))

;; The adjacency shorthand: a row is (from to ...), and the destination
;; is both the event name and where it goes.
(define (door) (make-state-machine 'shut '((shut open) (open shut locked)
                                           (locked open))))

(let ((s (door)))
  (want 'it-starts-where-it-was-told (state-current s) 'shut)
  (want 'and-offers-what-leads-away (state-events s) '(open))
  (state-send! s 'open)
  (want 'sending-moves-it (state-current s) 'open)
  (want 'and-the-events-move-with-it (state-events s) '(shut locked)))

;; The states are the initial one first, then every other name in the
;; order it was first mentioned, so the generated spec reads the way
;; the caller wrote it.  Reading it back through the datum is how a
;; cell can see that order without reaching into the machine.
;;
;; The datum is (machine (spec ...) (state ...) (ctx ...) (strict ...)),
;; a tagged form and not a flat table, so the spec is reached through
;; the tag.  A first version of this cell ran assq straight at the
;; datum, whose head is the symbol `machine' -- which is a trap rather
;; than a wrong answer, and takes the rest of the file's verdicts with
;; it.
(define (datum-part d tag) (cadr (assq tag (cdr d))))
(let ((s (door)))
  (want 'the-datum-names-itself (car (state->datum s)) 'machine)
  (want 'the-state-order-follows-the-writing
        (cadr (assq 'states (datum-part (state->datum s) 'spec)))
        '(shut open locked))
  (want 'the-shorthand-made-an-edge-per-destination
        (cadr (assq 'transitions (datum-part (state->datum s) 'spec)))
        '((shut open open) (open shut shut) (open locked locked)
          (locked open open)))
  (want 'and-the-datum-carries-where-it-is-now
        (datum-part (state->datum s) 'state) 'shut))

;; The initial state comes FIRST, and saying so needs a machine whose
;; initial state is not also the first name a row mentions -- in the
;; door above, `shut' heads the first row too, so a states list built
;; from the rows alone comes out in the same order and the claim is
;; unfalsifiable.  Here the initial state appears only as a
;; destination.
(let ((s (make-state-machine 'ready '((armed firing) (firing ready)
                                      (ready armed)))))
  (want 'the-initial-state-heads-the-list
        (cadr (assq 'states (datum-part (state->datum s) 'spec)))
        '(ready armed firing)))

;; An event the current state does not offer is refused by send! and
;; merely declined by transition!, which is the only difference between
;; them: one is for an event the caller chose, the other for one it did
;; not.
;; What state-send! does with an unavailable event is NOT pinned here.
;; It is documented as raising and does not, and that disagreement has
;; its own cell -- defect-s01-send-is-quiet-about-impossible-events.ss
;; -- because it is a defect rather than a property.  Pinning today's
;; behaviour here would make this file argue against that one.
(let ((s (door)))
  (want 'sending-an-unavailable-event-does-not-move-it
        (begin (state-send! s 'locked) (state-current s)) 'shut)
  (want 'transition-declines-instead (state-transition! s 'locked) #f)
  (want 'still-alone (state-current s) 'shut)
  (want 'and-takes-an-available-one (state-transition! s 'open) #t)
  (want 'having-moved (state-current s) 'open))

;; THE ROUND TRIP.  The datum carries the spec, the current state and
;; the context; it does not carry bindings, because they are
;; procedures.
(let ((s (door)))
  (state-send! s 'open)
  (let ((back (datum->state (state->datum s) '())))
    (want 'the-round-trip-keeps-where-it-had-got-to
          (state-current back) 'open)
    (want 'and-what-it-can-do-from-there
          (state-events back) '(shut locked))
    (want 'and-the-datum-of-the-copy-equals-the-original
          (equal? (state->datum back) (state->datum s)) #t)
    (state-send! back 'locked)
    (want 'and-the-copy-runs (state-current back) 'locked)
    (want 'without-moving-the-original (state-current s) 'open)))

;; The context travels only if it is itself a datum, and the refusal
;; arrives at the WRITE rather than at the load -- which is the useful
;; end, since the caller that put a procedure in the context is there.
(let ((s (make-event-state-machine
           (list (list 'states '(a b)) (list 'initial 'a)
                 (list 'transitions '((a go b))))
           '() '((count . 1)))))
  (want 'a-datum-context-is-carried
        (state-ctx (datum->state (state->datum s) '())) '((count . 1)))
  (want 'and-it-is-in-the-datum-under-its-own-tag
        (datum-part (state->datum s) 'ctx) '((count . 1))))
;; The refusal arrives at the CONSTRUCTION, earlier still: a context
;; that cannot be written is rejected when it is handed over, not when
;; someone tries to save it.  A first version of this cell guarded the
;; save and never reached it, which is the guard being placed after the
;; thing it was meant to catch.
(want 'a-context-holding-a-procedure-is-refused-when-it-is-handed-over
      (raises?
        (lambda ()
          (make-event-state-machine
            (list (list 'states '(a b)) (list 'initial 'a)
                  (list 'transitions '((a go b))))
            '() (list (cons 'fn (lambda (x) x)))))) #t)

;; ACTIONS ARE NAMES AND NOTHING HERE CALLS THEM.  A send answers the
;; names the transition asked for; who runs them, and in what order
;; relative to everything else, stays in the caller's code.  So a
;; binding for an action is never consulted, and a machine read back
;; without one still names it.
(let* ((seen '())
       (note (lambda (ctx) (set! seen (cons 'rang seen)) ctx))
       (s (make-event-state-machine
            (list (list 'states '(quiet ringing))
                  (list 'initial 'quiet)
                  ;; A row is (from event to guard action): five
                  ;; positions, with the guard #f when there is none.
                  ;; A four-element row puts the action in the guard's
                  ;; place, where it is a name that is looked up and
                  ;; asked whether the transition may happen.
                  (list 'transitions '((quiet ring ringing #f bell))))
            (list (cons 'bell note)))))
  (want 'a-send-answers-the-actions-it-named (state-send! s 'ring) '(bell))
  (want 'and-it-moved (state-current s) 'ringing)
  (want 'and-nothing-here-ran-the-binding (length seen) 0)
  (let ((back (datum->state (state->datum s) '())))
    (want 'an-action-name-needs-no-binding-to-read-back
          (state-current back) 'ringing)
    (want 'and-the-name-still-comes-out-of-a-step
          (state-send! (datum->state
                         (state->datum
                           (make-event-state-machine
                             (list (list 'states '(quiet ringing))
                                   (list 'initial 'quiet)
                                   (list 'transitions
                                         '((quiet ring ringing #f bell))))
                             '()))
                         '())
                       'ring)
          '(bell))))

;; A GUARD NAME IS DIFFERENT, and this is the asymmetry the round trip
;; turns on: a guard is CALLED, to decide whether the transition may
;; happen, so its binding has to be there.  Missing, it is refused at
;; construction and refused again at the read-back -- which is the
;; useful pair, since a spec assembled by hand and a spec loaded from a
;; file are the two ways a machine arrives with a name nobody bound.
(define (guarded bindings)
  (make-event-state-machine
    (list (list 'states '(a b)) (list 'initial 'a)
          (list 'transitions '((a go b ok #f))))
    bindings))
(want 'an-unbound-guard-is-refused-at-construction
      (raises? (lambda () (guarded '()))) #t)
(let ((d (state->datum (guarded (list (cons 'ok (lambda (ctx) #t)))))))
  (want 'and-refused-again-at-the-read-back
        (raises? (lambda () (datum->state d '()))) #t)
  (want 'while-supplying-it-succeeds
        (state-current (datum->state d (list (cons 'ok (lambda (ctx) #t)))))
        'a))

;; The machine handed out is the state as of the call and cannot become
;; a second way to alter the cell.
(let ((s (door)))
  (let ((m (state-machine s)))
    (state-send! s 'open)
    (want 'the-handed-out-machine-did-not-follow
          (equal? (state-current s) 'open) #t)
    (want 'and-is-still-what-it-was (machine? m) #t)))

;; Refusals in the shorthand, each aimed at a mistake that would
;; otherwise be reported against a transition the caller never wrote.
(want 'a-non-symbol-initial-refused
      (raises? (lambda () (make-state-machine "shut" '((shut open))))) #t)
(want 'a-non-list-table-refused
      (raises? (lambda () (make-state-machine 'shut 'open))) #t)
(want 'an-empty-row-refused
      (raises? (lambda () (make-state-machine 'shut '(())))) #t)
(want 'a-non-symbol-state-refused
      (raises? (lambda () (make-state-machine 'shut '((shut 7))))) #t)
(want 'not-a-state-machine-refused
      (raises? (lambda () (state-current (vector 'gam-state)))) #t)

(display (if (null? fails) #t (reverse fails)))
