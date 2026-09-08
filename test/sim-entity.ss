;; expect: #t
;; (sim entity): a fixed-capacity store of entities with generational
;; handles.  A handle is (slot . generation); destroying an entity bumps
;; the generation of its slot, so a handle kept past the destruction can
;; never address whatever is spawned into that slot next.  That property
;; is the reason to have this library rather than an index, and it is the
;; first thing pinned here.
(import (rnrs) (sim entity))

(define (refused? who thunk)
  (guard (e (#t (and (error? e) (eq? (condition-who e) who)))) (thunk) #f))
(define (report name ok) (unless ok (display "  FAIL ") (display name) (newline)) ok)

;; ---- spawn, read, destroy ----
(define w (make-entities 4))
(define a (entity-spawn! w))
(define basic-ok
  (and (entity-alive? w a)
       (= (entity-count w) 1)
       (begin (entity-set! w a 'hp 10) (= (entity-ref w a 'hp 0) 10))
       (eq? (entity-ref w a 'missing 'none) 'none)
       (begin (entity-destroy! w a) (not (entity-alive? w a)))
       (= (entity-count w) 0)
       (begin (entity-destroy! w a) #t)))          ; destroying twice is quiet

;; ---- the whole point: a recycled slot does not answer the old handle ----
(define recycle-ok
  (let* ((w (make-entities 2))
         (old (entity-spawn! w)))
    (entity-set! w old 'tag 'first)
    (entity-destroy! w old)
    (let ((new (entity-spawn! w)))               ; same slot, next generation
      (and (= (car new) (car old))               ; it really is the same slot
           (not (equal? new old))
           (entity-alive? w new)
           (not (entity-alive? w old))
           (eq? (entity-ref w old 'tag 'gone) 'gone)
           (eq? (entity-ref w new 'tag 'empty) 'empty)))))

;; ---- writing to something that no longer exists is an error, not a no-op ----
(define dead-write-ok
  (let* ((w (make-entities 2)) (h (entity-spawn! w)))
    (entity-destroy! w h)
    (and (refused? 'entity-set! (lambda () (entity-set! w h 'hp 1)))
         (refused? 'entity-set! (lambda () (entity-set! w (cons 99 0) 'hp 1)))
         (eq? (entity-ref w h 'hp 'gone) 'gone))))  ; reading a dead handle is quiet

;; ---- shapes refused by name ----
(define refuse-ok
  (and (refused? 'make-entities (lambda () (make-entities 0)))
       (refused? 'make-entities (lambda () (make-entities 'many)))
       (refused? 'entity-set! (lambda ()
                                (let* ((w (make-entities 2)) (h (entity-spawn! w)))
                                  (entity-set! w h "hp" 1))))
       (let ((w (make-entities 2)))
         (entity-spawn! w) (entity-spawn! w)
         (refused? 'entity-spawn! (lambda () (entity-spawn! w))))))   ; capacity is fixed

;; ---- each walks a snapshot ----
(define each-ok
  (let ((w (make-entities 8)) (seen '()) (spawned '()))
    (let ((h1 (entity-spawn! w)) (h2 (entity-spawn! w)) (h3 (entity-spawn! w)))
      (entity-set! w h1 'n 1) (entity-set! w h2 'n 2) (entity-set! w h3 'n 3)
      (entity-each w (lambda (h)
                       (set! seen (cons (entity-ref w h 'n 0) seen))
                       (when (= (entity-ref w h 'n 0) 1)
                         (entity-destroy! w h2)                 ; destroyed mid-walk: skipped
                         (set! spawned (cons (entity-spawn! w) spawned)))))  ; spawned mid-walk: not visited
      (and (equal? (reverse seen) '(1 3))
           (= (length spawned) 1)
           (entity-alive? w (car spawned))))))

(display (and (report "basic" basic-ok) (report "recycle" recycle-ok)
              (report "dead-write" dead-write-ok) (report "refuse" refuse-ok)
              (report "each" each-ok)))
(newline)
