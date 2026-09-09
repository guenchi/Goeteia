;; expect: #t
;; (sim entity): spawning with components, all or nothing.
;;
;; Written out by hand -- spawn, then set each component -- a failure
;; part way through leaves a half-built entity alive in the world, and
;; it looks exactly like a finished one.  Nothing raises later; the
;; entity simply behaves as though it were missing a piece, somewhere
;; else, at some other time.
;;
;; The rollback covers what can be rolled back.  A Scheme condition
;; raised while the components are being written is caught, the entity
;; is destroyed, and the original condition is re-raised unchanged.  A
;; host exception is not: it ends the program before any handler runs,
;; which is a property of the runtime and not of this procedure.  That
;; is also why the rows carry VALUES and not procedures -- whatever
;; computes a value runs in the caller, before this is called, so a
;; factory that talks to the host cannot fail half way through here.
;;
;; Today that rollback is insurance and not something that happens: the
;; checks below refuse every wrong row before the entity exists, so the
;; writes that follow cannot fail.  It is here for the day entity-set!
;; grows a check of its own.  An insurance that has never paid out and
;; one that does not exist read the same in a document, so what it does
;; when it does pay is verified by mutation, not left to the prose.
(import (rnrs) (sim entity))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (refuses? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))

(check "every component is there afterwards"
       (let* ((w (make-entities 8))
              (h (entity-spawn-with! w '((pos . 1) (hp . 7) (name . hero)))))
         (and (entity-alive? w h)
              (equal? (entity-ref w h 'pos #f) 1)
              (equal? (entity-ref w h 'hp #f) 7)
              (equal? (entity-ref w h 'name #f) 'hero))))
(check "an empty row list still makes an entity"
       (let* ((w (make-entities 8)) (h (entity-spawn-with! w '())))
         (and (entity-alive? w h) (= (entity-count w) 1))))

;; ---- what these cells can and cannot say ----
;; The rollback cannot be reached from here.  Every way a row can be
;; wrong is refused BEFORE the entity is made, and the writes that
;; follow cannot fail: entity-set! raises for a key that is not a
;; symbol (refused already) and for a stale handle (this one is one
;; call old).  So a cell that fed a bad row and then checked that no
;; entity survived would pass because NOTHING WAS EVER THROWN, not
;; because the rollback worked -- green for the wrong reason, which is
;; the same as not being there.
;;
;; So these two cells assert the reachable fact: that the intermediate
;; state cannot be produced.  The rollback itself is verified by
;; mutation instead -- replacing the second write with one that raises,
;; then checking that no entity is left and that the very same
;; condition object comes back out -- and that check is recorded with
;; the change rather than living here, because it cannot be written
;; against the library as it stands.
;; NOTE the name: this says no entity SURVIVES, not that the row was
;; refused before one was made.  It cannot tell those apart -- with the
;; pre-check removed the write raises and the rollback destroys the
;; entity, and the count is 0 either way.  Measured: dropping the
;; symbol pre-check leaves every cell in this file green.  The stronger
;; claim would need to see the entity that briefly existed, and nothing
;; here can.
(check "no entity survives a bad row"
       (let ((w (make-entities 8)))
         (guard (e (#t #t))
           (entity-spawn-with! w (list (cons 'pos 1) (cons 42 2) (cons 'hp 3))))
         (= (entity-count w) 0)))
(check "and the world is still usable afterwards"
       (let ((w (make-entities 8)))
         (guard (e (#t #t))
           (entity-spawn-with! w (list (cons 'pos 1) (cons 42 2))))
         (let ((h (entity-spawn-with! w '((pos . 9)))))
           (and (entity-alive? w h) (equal? (entity-ref w h 'pos #f) 9)))))

;; ---- a duplicate key is refused before anything is written ----
(check "a duplicate component name is refused"
       (refuses? (lambda ()
                   (entity-spawn-with! (make-entities 8)
                                       '((pos . 1) (hp . 2) (pos . 3))))))
(check "and the refusal costs no entity"
       (let ((w (make-entities 8)))
         (guard (e (#t #t))
           (entity-spawn-with! w '((pos . 1) (pos . 3))))
         (= (entity-count w) 0)))

;; ---- shapes that are not rows ----
(check "a row that is not a pair is refused"
       (refuses? (lambda () (entity-spawn-with! (make-entities 8) '(pos)))))
(check "rows that are not a list are refused"
       (refuses? (lambda () (entity-spawn-with! (make-entities 8) 'pos))))
(display (= failed 0))
