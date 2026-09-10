;; expect: #t
;; What this cell is the only evidence for: (gam party) holds
;; generational handles, so a slot that is recycled does not hand its
;; new occupant the old one's membership or selection.
;;
;; This is the reason the library exists rather than a detail of it.  A
;; roster of direct references cannot tell the two apart: the slot is
;; the same slot, and whoever spawns into it next is on the roster and
;; possibly selected, without anything having gone wrong at any single
;; step.
(import (rnrs) (gam party) (sim entity))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (raises? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))

;; THE CELL THIS LIBRARY IS FOR.  One entity, added and selected; kill
;; it, and spawn again so the store hands back the same slot.  The new
;; entity must be a stranger.
(let* ((w (make-entities 8))
       (a (entity-spawn! w))
       (p (make-party)))
  (party-add! p w a)
  (party-select! p w a)
  (entity-destroy! w a)
  (let ((b (entity-spawn! w)))
    (want 'the-slot-really-was-recycled
          (equal? a b) #f)
    (want 'the-recycled-slot-is-not-a-member (party-members p) (list a))
    (want 'and-the-new-entity-is-not-one
          (let mem ((l (party-members p)))
            (and (pair? l) (or (equal? (car l) b) (mem (cdr l))))) #f)
    (party-prune! p w)
    (want 'pruning-drops-the-dead-handle (party-members p) '())
    (want 'and-clears-a-selection-that-went-with-it (party-selected p) #f)))

;; A roster keeps the order it was built in, because a party is a list
;; the player arranged rather than a set.
(let* ((w (make-entities 8))
       (a (entity-spawn! w)) (b (entity-spawn! w)) (c (entity-spawn! w))
       (p (make-party)))
  (party-add! p w c)
  (party-add! p w a)
  (party-add! p w b)
  (want 'members-keep-the-order-they-were-added (party-members p) (list c a b))
  (party-add! p w a)
  (want 'adding-twice-does-not-duplicate (party-members p) (list c a b)))

;; Removing is by handle and quiet about a stranger, because it asks
;; for a state that already holds.
(let* ((w (make-entities 8))
       (a (entity-spawn! w)) (b (entity-spawn! w))
       (p (make-party)))
  (party-add! p w a)
  (party-remove! p b)
  (want 'removing-a-stranger-changes-nothing (party-members p) (list a))
  (party-remove! p a)
  (want 'removing-a-member-takes-it (party-members p) '()))

;; A handle is a pair of slot and generation, so a caller that REBUILDS
;; one -- read back from a save, or assembled from two numbers it was
;; holding -- has a handle that is equal? to the roster's and not eq?
;; to it.  Comparing by identity would leave that member on the roster
;; and report nothing, and the caller would be right to believe it had
;; removed them.
(let* ((w (make-entities 8))
       (a (entity-spawn! w))
       (rebuilt (cons (car a) (cdr a)))
       (p (make-party)))
  (party-add! p w a)
  (want 'a-rebuilt-handle-is-not-the-same-object (eq? a rebuilt) #f)
  (want 'but-it-names-the-same-entity (equal? a rebuilt) #t)
  (party-remove! p rebuilt)
  (want 'and-removing-by-it-works (party-members p) '()))

;; The same for selection, which also compares.
(let* ((w (make-entities 8))
       (a (entity-spawn! w))
       (rebuilt (cons (car a) (cdr a)))
       (p (make-party)))
  (party-add! p w a)
  (party-select! p w rebuilt)
  (party-remove! p a)
  (want 'a-selection-made-by-a-rebuilt-handle-is-still-cleared
        (party-selected p) #f))

;; Removing the selected member unselects, so no caller can hold a
;; selection that is not on the roster.
(let* ((w (make-entities 8))
       (a (entity-spawn! w)) (b (entity-spawn! w))
       (p (make-party)))
  (party-add! p w a)
  (party-add! p w b)
  (party-select! p w b)
  (party-remove! p a)
  (want 'removing-someone-else-keeps-the-selection (party-selected p) b)
  (party-remove! p b)
  (want 'removing-the-selected-clears-it (party-selected p) #f))

;; Selection is restricted to live members; #f is how a caller says
;; nobody and is the only value accepted that is not one.
(let* ((w (make-entities 8))
       (a (entity-spawn! w)) (b (entity-spawn! w))
       (p (make-party)))
  (party-add! p w a)
  (want 'selecting-a-non-member-refused
        (raises? (lambda () (party-select! p w b))) #t)
  (party-select! p w a)
  (party-select! p w #f)
  (want 'nobody-is-a-selection (party-selected p) #f)
  (entity-destroy! w a)
  (want 'selecting-a-dead-member-refused
        (raises? (lambda () (party-select! p w a))) #t))

;; Adding a dead handle is refused rather than accepted and pruned
;; later: the caller has a handle it believes in, and the earliest
;; place to say otherwise is here.
(let* ((w (make-entities 8))
       (a (entity-spawn! w))
       (p (make-party)))
  (entity-destroy! w a)
  (want 'adding-a-dead-entity-refused
        (raises? (lambda () (party-add! p w a))) #t))

;; Pruning walks the roster as it stands on entry, so it examines every
;; member exactly once even though it removes as it goes.  Three dead
;; in a row is the arrangement that catches a walk over a list being
;; rebuilt underneath it.
(let* ((w (make-entities 8))
       (a (entity-spawn! w)) (b (entity-spawn! w))
       (c (entity-spawn! w)) (d (entity-spawn! w))
       (p (make-party)))
  (for-each (lambda (h) (party-add! p w h)) (list a b c d))
  (entity-destroy! w a)
  (entity-destroy! w b)
  (entity-destroy! w c)
  (party-prune! p w)
  (want 'pruning-drops-every-dead-one-in-a-run (party-members p) (list d)))

;; A fresh party is empty and has nobody selected.
(let ((p (make-party)))
  (want 'a-new-party-is-empty (party-members p) '())
  (want 'with-nobody-selected (party-selected p) #f)
  (want 'and-it-is-a-party (party? p) #t))
;; The type test is structural -- tag and shape -- as it is in every
;; library here, so a correctly shaped vector IS a party and the test
;; is not a forgery detector.  What it does catch is the mistake a
;; caller actually makes: passing something else entirely, or a vector
;; of the wrong shape.
(want 'a-correctly-shaped-vector-is-a-party
      (party? (vector 'gam-party '() #f)) #t)
(want 'a-vector-of-the-wrong-shape-is-not (party? (vector 'gam-party '())) #f)
(want 'another-tag-is-not (party? (vector 'gam-window '() #f)) #f)
(want 'a-list-is-not (party? (list 'gam-party '() #f)) #f)
(want 'and-an-operation-on-one-refuses
      (raises? (lambda () (party-members (list 'gam-party '() #f)))) #t)

(display (if (null? fails) #t (reverse fails)))
