;; expect: #t
;; on-cleanup: a resource acquired inside an effect is released when
;; the effect reruns or is disposed.  Registered thunks run in reverse
;; order of registration, BEFORE the next run's body, on
;; dispose-effect!, through a root's disposer, and when a parent's
;; rerun disposes a child; a thunk registered outside any effect is an
;; error by name.  Without this the effect that opened a websocket on
;; the last run has no way to close it on this one.
(import (rnrs) (web reactive))

(define log '())
(define (note! x) (set! log (cons x log)))
(define (refused? who thunk)
  (guard (e (#t (and (error? e) (eq? (condition-who e) who))))
    (thunk) #f))

;; ---- rerun: the old run's cleanup precedes the new run's body ----
(define url (signal "a"))
(define e1
  (effect (lambda ()
            (let ((u (signal-ref url)))
              (note! (list 'open u))
              (on-cleanup (lambda () (note! (list 'close u))))))))
(signal-set! url "b")
(define rerun-ok
  (equal? (reverse log) '((open "a") (close "a") (open "b"))))

;; ---- dispose: the last run's cleanup runs once, and never again ----
(set! log '())
(dispose-effect! e1)
(signal-set! url "c")                 ; a dead effect neither reruns nor cleans up again
(define dispose-ok (equal? log '((close "b"))))

;; ---- several cleanups: reverse order of registration ----
(set! log '())
(define e2 (effect (lambda ()
                     (on-cleanup (lambda () (note! 1)))
                     (on-cleanup (lambda () (note! 2)))
                     (on-cleanup (lambda () (note! 3))))))
(dispose-effect! e2)
(define order-ok (equal? log '(1 2 3)))          ; log is reversed: ran 3, 2, 1

;; ---- a child's cleanup runs when the parent reruns (the child dies with it) ----
(set! log '())
(define tick (signal 0))
(define e3 (effect (lambda ()
                     (signal-ref tick)
                     (effect (lambda () (on-cleanup (lambda () (note! 'child-closed))))))))
(signal-set! tick 1)
(define child-ok (equal? log '(child-closed)))
(dispose-effect! e3)

;; ---- child before parent: the parent's cleanup runs after its children's ----
;; A child's resource usually depends on the parent's (a subscription on
;; a connection), so the parent must still be open while the child closes.
(set! log '())
(define tock (signal 0))
(define e3b (effect (lambda ()
                      (signal-ref tock)
                      (on-cleanup (lambda () (note! 'parent-closed)))
                      (effect (lambda () (on-cleanup (lambda () (note! 'child-closed))))))))
(signal-set! tock 1)                              ; rerun: child, then parent
(define order-rerun (reverse log))
(set! log '())
(dispose-effect! e3b)                             ; dispose: child, then parent
(define child-first-ok
  (and (equal? order-rerun '(child-closed parent-closed))
       (equal? (reverse log) '(child-closed parent-closed))))

;; ---- a root's disposer releases what was opened inside it ----
(set! log '())
(define r (root (lambda () (effect (lambda () (on-cleanup (lambda () (note! 'root-closed))))) 'made)))
(define root-ok
  (and (eq? (car r) 'made)
       (null? log)
       (begin ((cdr r)) (equal? log '(root-closed)))))

;; ---- a cleanup registered before the body raised still runs on dispose ----
(set! log '())
(define bomb (signal #f))
(define e4 (effect (lambda ()
                     (on-cleanup (lambda () (note! 'released)))
                     (when (signal-ref bomb) (error 'e4 "boom")))))
(define raised-ok
  (and (guard (ex (#t (eq? (condition-who ex) 'e4)))
         (signal-set! bomb #t) #f)             ; the rerun raises after its own on-cleanup ran... see below
       ;; the first run's cleanup ran before the raising rerun's body
       (equal? (car (reverse log)) 'released)
       (begin (dispose-effect! e4) #t)
       ;; the raising run had registered its cleanup before raising: dispose runs it too
       (= (length log) 2)))

;; ---- a cleanup that raises does not rob the others of their turn ----
;; All registered thunks run; what one raised is re-raised afterwards,
;; so the caller still hears about it, but not at the price of a leak.
(set! log '())
(define e5 (effect (lambda ()
                     (on-cleanup (lambda () (note! 'first-registered)))
                     (on-cleanup (lambda () (error 'cleanup-bomb "boom")))
                     (on-cleanup (lambda () (note! 'last-registered))))))
(define raising-cleanup-ok
  (and (guard (ex (#t (eq? (condition-who ex) 'cleanup-bomb)))
         (dispose-effect! e5) #f)               ; the error still surfaces
       (equal? log '(first-registered last-registered))))   ; ...after every thunk ran (reverse order)

;; ---- a cleanup that disposes its own effect ends it: the new body must not run ----
(set! log '())
(define kill (signal 0))
(define e6 #f)
(set! e6 (effect (lambda ()
                   (signal-ref kill)
                   (note! 'body)
                   (on-cleanup (lambda () (dispose-effect! e6))))))
(signal-set! kill 1)
(define self-dispose-ok (equal? log '(body)))   ; once, on the first run only

;; ---- one child's cleanup raising does not stop its siblings or its parent ----
;; Tree disposal is one transaction: every release runs, the first
;; condition surfaces at the end.
(set! log '())
(define tree (signal 0))
(define e7 (effect (lambda ()
                     (signal-ref tree)
                     (on-cleanup (lambda () (note! 'parent)))
                     (effect (lambda () (on-cleanup (lambda () (error 'c1 "boom")))))
                     (effect (lambda () (on-cleanup (lambda () (note! 'c2))))))))
(define tree-dispose-ok
  (and (guard (ex (#t (eq? (condition-who ex) 'c1)))
         (dispose-effect! e7) #f)
       (equal? (reverse log) '(c2 parent))))
(set! log '())
(define e7b (effect (lambda ()
                      (signal-ref tree)
                      (on-cleanup (lambda () (note! 'parent)))
                      (effect (lambda () (on-cleanup (lambda () (error 'c1 "boom")))))
                      (effect (lambda () (on-cleanup (lambda () (note! 'c2))))))))
(define tree-rerun-ok                             ; the same, reached through a rerun
  (and (guard (ex (#t (eq? (condition-who ex) 'c1)))
         (signal-set! tree 1) #f)
       (equal? (reverse log) '(c2 parent))))
(dispose-effect! e7b)

;; ---- what a cleanup raises is passed on as raised, even #f ----
(define e8 (effect (lambda () (on-cleanup (lambda () (raise #f))))))
(define raise-false-ok
  (guard (ex (#t (eq? ex #f))) (dispose-effect! e8) 'nothing-raised))

;; ---- a root body is an owner: what it registers runs through its disposer ----
(set! log '())
(define r2 (root (lambda () (on-cleanup (lambda () (note! 'root-body))) 'made)))
(define root-body-ok
  (and (eq? (car r2) 'made) (null? log)
       (begin ((cdr r2)) (equal? log '(root-body)))))

;; ---- inside a cleanup there is no run to clean up after ----
(set! log '())
(define nest (signal 0))
(define e9 (effect (lambda ()
                     (signal-ref nest)
                     (on-cleanup (lambda () (note! 'clean) (on-cleanup (lambda () (note! 'nested))))))))
(define nested-ok
  (and (refused? 'on-cleanup (lambda () (signal-set! nest 1)))
       (equal? log '(clean))))
(dispose-effect! e9)

;; ---- ...even when the disposal happens inside another effect's body ----
;; The outer effect is live and current, so a check that only asks "is
;; some effect running?" would hang the victim's leftover on it.
(set! log '())
(define victim (effect (lambda () (on-cleanup (lambda () (note! 'victim-clean) (on-cleanup (lambda () (note! 'stray))))))))
(define outer-refused #f)
(define outer (effect (lambda ()
                        (set! outer-refused (refused? 'on-cleanup (lambda () (dispose-effect! victim)))))))
(dispose-effect! outer)                           ; if the stray had landed here, it would run now
(define nested-from-effect-ok
  (and outer-refused (equal? log '(victim-clean))))

;; ---- outside any effect there is nothing to clean up after ----
(define outside-ok (refused? 'on-cleanup (lambda () (on-cleanup (lambda () 'x)))))

(and rerun-ok dispose-ok order-ok child-ok child-first-ok root-ok raised-ok raising-cleanup-ok
     self-dispose-ok tree-dispose-ok tree-rerun-ok raise-false-ok root-body-ok nested-ok nested-from-effect-ok outside-ok)
