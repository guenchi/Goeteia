;; Copyright 2026 guenchi
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;; One mutable place to keep a machine that is itself immutable.
;;
;; (lng machine) is the state machine: a spec that is a datum, guards
;; and actions that are names, and a machine VALUE that never changes --
;; machine-step answers a new machine rather than altering the old one.
;; That is the right shape for something you want to write to a file,
;; read back, diff and draw.  It is not the shape of a thing in a world.
;;
;; A thing in a world has one current state and many observers, and the
;; observers do not all know each other.  Threading a new machine value
;; out to every one of them means every one of them has to know where
;; the value is kept, which is to say the owner has to be written again
;; at each of them, slightly differently.  This library is that owner,
;; written once: a cell holding a machine, and the small number of
;; operations that read it or replace what is in it.
;;
;; THE CELL IS REPLACED ONLY BY A STEP THAT RETURNED.  machine-step
;; raises when more than one guard holds -- a statement about the model
;; rather than a failure to route around -- and raises for an event with
;; no transition if, and only if, the spec says (on-unknown error).
;; Because the cell is written only with what that call returned, a
;; raise leaves the previous machine in place: the thing is still in the
;; state it was in, and a caller that catches the condition is looking
;; at a machine no partial step has been applied to.  This is the
;; property that makes a mutable owner safe to have, and it is worth
;; stating because it is invisible at the call site.
;;
;; WITHOUT THAT CLAUSE AN UNKNOWN EVENT IS A QUIET NO-OP: the machine
;; comes back unchanged and the actions are empty.  That default is the
;; reason state-transition! is worth having beside state-send! -- on a
;; spec that does not ask to raise.  THE ADJACENCY-TABLE SHORTHAND IS
;; THE EXCEPTION: make-state-machine emits (on-unknown error) itself,
;; because every event it can express is named after its destination,
;; so an unavailable one is a destination the caller named and cannot
;; reach -- a fault in the caller rather than an ordinary answer.  A
;; machine built from a raw spec still decides this for itself.  On such
;; a spec, state-send! cannot tell a caller whether anything happened --
;; empty actions are what an unavailable event answers AND what a
;; transition carrying no actions answers -- so a caller that needs to
;; know asks state-transition!, which reports it as a boolean, or puts
;; (on-unknown error) in the spec and lets the mistake raise.
;;
;; AMBIGUITY IS CAUGHT IN TWO PLACES AND ONLY THE LATER ONE REACHES
;; HERE.  Two transitions sharing a (from event) key with NO guards are
;; refused by make-machine, so such a spec never becomes a machine at
;; all and no caller of this library can be holding one.  Two sharing
;; that key WITH guards are accepted, because whether both can hold at
;; once is a question about the guards and not about the spec; if both
;; then do hold, the step raises.  Nothing here picks a winner in either
;; case, and in the raising one the cell still holds what it held
;; before -- which, with the paragraph above, is the whole of what a
;; caller needs to know about a step that did not go through.
;;
;; IT ADDS NO BEHAVIOUR.  Nothing here interprets a state, times a
;; state, or decides what a transition means.  It holds one and passes
;; the questions through.  Anything richer belongs either in the spec,
;; where it can be written down and read back, or in the caller.
;;
;; THERE ARE TWO CONSTRUCTORS, and the shorter name is the narrower one.
;; make-event-state-machine takes a full spec and is the general case.
;; make-state-machine takes an adjacency table -- rows of (from to ...)
;; -- and derives a spec in which EVERY EVENT IS NAMED AFTER ITS
;; DESTINATION.  That shorthand is worth having for the common machine
;; whose events are just "go there", and its limits follow from the one
;; sentence: it cannot express an event whose name differs from the
;; state it leads to, it cannot express two different events leading
;; from one state to the same destination, and it cannot express a guard
;; or an action at all.  A machine that needs any of those wants the
;; spec form, and converting is not a rewrite -- the adjacency table is
;; a spec with the names filled in one way.
(library (gam state)
  (export make-state-machine make-event-state-machine state?
          state-machine state-current state-events state-ctx
          state-send! state-transition! state->datum datum->state)
  (import (rnrs) (lng machine))

  ;; #(gam-state machine)
  (define ($s? s)
    (and (vector? s) (= (vector-length s) 2)
         (eq? (vector-ref s 0) 'gam-state)
         (machine? (vector-ref s 1))))
  (define ($need-s who s)
    (unless ($s? s) (error who "not a state" s)))
  (define ($m s) (vector-ref s 1))
  (define ($m! s v) (vector-set! s 1 v))

  (define (state? s) ($s? s))

  (define (make-event-state-machine spec bindings . context)
    (vector 'gam-state
            (make-machine spec bindings
                          (if (null? context) '() (car context)))))

  ;; The machine value itself, for the questions (lng machine) answers
  ;; and this does not -- machine-spec, machine-transitions.  It is safe
  ;; to hand out because it is immutable: what comes back is the state
  ;; as of this call and cannot become a second way to alter the cell.
  (define (state-machine s) ($need-s 'state-machine s) ($m s))

  (define (state-current s) ($need-s 'state-current s) (machine-state ($m s)))
  (define (state-events s) ($need-s 'state-events s) (machine-events ($m s)))
  (define (state-ctx s) ($need-s 'state-ctx s) (machine-ctx ($m s)))
  (define (state->datum s) ($need-s 'state->datum s) (machine->datum ($m s)))

  (define (datum->state datum bindings)
    (vector 'gam-state (datum->machine datum bindings)))

  ;; Answers the actions the transition named, and writes the cell only
  ;; if it got that far.
  (define (state-send! s event . context)
    ($need-s 'state-send! s)
    (let ((m ($m s)))
      (let-values (((next actions)
                    (machine-step m event
                                  (if (null? context) (machine-ctx m) (car context)))))
        ($m! s next)
        actions)))

  ;; The adjacency shorthand.  The states are the initial one followed
  ;; by every other name in the order it is first mentioned, so the
  ;; generated spec reads in the order the caller wrote it.
  (define (make-state-machine initial transitions)
    (unless (symbol? initial)
      (error 'make-state-machine "an initial state is a symbol" initial))
    (unless (list? transitions)
      (error 'make-state-machine "an adjacency table is a list of rows" transitions))
    ;; Checked here rather than left to the spec check, because by then
    ;; the error would name a transition the caller never wrote.
    (for-each
     (lambda (row)
       (unless (and (list? row) (pair? row))
         (error 'make-state-machine "a row is (from to ...)" row))
       (for-each
        (lambda (name)
          (unless (symbol? name)
            (error 'make-state-machine "a state is a symbol" name row)))
        row))
     transitions)
    (let ((states (list initial)) (edges '()))
      (for-each
       (lambda (row)
         (for-each
          (lambda (name)
            (unless (memq name states) (set! states (cons name states))))
          row)
         ;; from, event, to -- with the destination serving as both the
         ;; event name and the destination.
         (for-each
          (lambda (next) (set! edges (cons (list (car row) next next) edges)))
          (cdr row)))
       transitions)
      ;; (on-unknown error), which the shorthand did not emit.
      ;;
      ;; state-send! is documented as raising where state-transition!
      ;; declines -- that distinction is why both exist -- and without
      ;; this clause it held for no machine built here: an event the
      ;; caller CHOSE and that cannot happen answered no actions and
      ;; left the machine where it was.  Silence and a thing that did
      ;; not move is the worst symptom to debug, because it surfaces
      ;; later as something that "sometimes doesn't work".
      ;;
      ;; Only the shorthand changes.  make-event-state-machine takes
      ;; the clause from the caller's own spec, so a machine assembled
      ;; from a raw spec keeps deciding this for itself, and a caller
      ;; who wants the quiet default still has state-transition!, which
      ;; reports availability as a boolean rather than raising.
      (make-event-state-machine
       (list (list 'states (reverse states))
             (list 'initial initial)
             (list 'transitions (reverse edges))
             (list 'on-unknown 'error))
       '())))

  ;; Answers whether it went, rather than raising when it did not.  This
  ;; is the one place that differs from state-send!, and it exists for
  ;; the caller that is asking "can it, and if so do it" about an event
  ;; it did not choose -- a key pressed, a row clicked.  An event that
  ;; is not available there is an ordinary answer and not a fault, so
  ;; the test is made first and nothing is sent unless it passes.
  (define (state-transition! s next)
    ($need-s 'state-transition! s)
    (and (memq next (state-events s))
         (begin (state-send! s next) #t))))
