;; expect: #t
;; The invariant lib/gam/state.ss calls "the property that makes a
;; mutable owner safe to have ... invisible at the call site": the cell
;; holding a machine is replaced only by a step that RETURNED, so a
;; raise leaves the previous machine in place.  Pinned here because the
;; s01 fix made the shorthand raise, which is the path that exercises it.
;;
;; It discriminates, and the discriminating part is the context.  codex
;; found that before the fix a rejected send carried a partial effect: a
;; quiet no-op still KEPT a replacement context while leaving the state
;; alone, so the datum changed even though nothing moved.  The raise now
;; prevents that -- the whole datum, context included, is unchanged.
;; Measured: datum-equal is #t on the fix and #f on the tree before it.
;; The sibling defect-s01 pins that the send raises; this pins that the
;; raise leaves nothing half-applied.
(import (rnrs) (gam state))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (raises? thunk)
  (guard (e ((error? e) #t) (else #f)) (thunk) #f))
(define (door)
  (make-state-machine 'shut '((shut open) (open shut locked) (locked open))))
(let ((s (door)))
  (let ((before (state->datum s)))
    (want 'a-rejected-send-raises
          (raises? (lambda () (state-send! s 'locked 'ctx))) #t)
    (want 'and-leaves-the-state-in-place (state-current s) 'shut)
    (want 'and-the-whole-datum-context-included
          (equal? (state->datum s) before) #t)))
(display (if (null? fails) #t fails))
