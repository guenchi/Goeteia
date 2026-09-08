;; expect: #t
;; (sim schedule): the systems that run each tick, ordered by a priority
;; number that lives in the data.  Equal priorities keep the order they
;; were added in, and that stays true across removals -- so what runs
;; when is readable from the registration, never from load order.
;;
;; A system that raises stops the tick.  That is the opposite of what
;; (lng effect) does for cleanups, and deliberately: a cleanup that is
;; skipped leaks a resource, while a tick that continues past a failed
;; system produces a half-updated world that looks complete.
(import (rnrs) (sim schedule))

(define (refused? who thunk)
  (guard (e (#t (and (error? e) (eq? (condition-who e) who)))) (thunk) #f))
(define (report name ok) (unless ok (display "  FAIL ") (display name) (newline)) ok)

(define log '())
(define (note! x) (set! log (cons x log)))
(define (noting x) (lambda (ctx dt) (note! x)))

;; ---- priority decides, and ties keep insertion order ----
(define order-ok
  (let ((s (make-schedule)))
    (schedule-add! s 'late 10 (noting 'late))
    (schedule-add! s 'first 0 (noting 'first))
    (schedule-add! s 'tie-a 5 (noting 'tie-a))
    (schedule-add! s 'tie-b 5 (noting 'tie-b))
    (set! log '())
    (schedule-run! s 'ctx 0.016)
    (equal? (reverse log) '(first tie-a tie-b late))))

;; ---- a removal does not disturb the order of the rest ----
(define stable-ok
  (let* ((s (make-schedule))
         (a (schedule-add! s 'a 5 (noting 'a)))
         (b (schedule-add! s 'b 5 (noting 'b)))
         (c (schedule-add! s 'c 5 (noting 'c))))
    (schedule-remove! b)
    (set! log '())
    (schedule-run! s 'ctx 0.016)
    (and (equal? (reverse log) '(a c))
         (begin (schedule-add! s 'b 5 (noting 'b))   ; re-added: it goes last among equals
                (set! log '())
                (schedule-run! s 'ctx 0.016)
                (equal? (reverse log) '(a c b))))))

;; ---- one name, one system ----
(define duplicate-ok
  (let ((s (make-schedule)))
    (schedule-add! s 'physics 0 (noting 'p))
    (and (refused? 'schedule-add! (lambda () (schedule-add! s 'physics 9 (noting 'q))))
         (let ((t (schedule-add! s 'other 1 (noting 'o))))
           (schedule-remove! t)
           (begin (schedule-add! s 'other 1 (noting 'o)) #t)))))  ; free again once removed

;; ---- removing during a tick takes effect at once ----
(define mid-tick-ok
  (let* ((s (make-schedule)) (victim #f))
    (schedule-add! s 'killer 0 (lambda (ctx dt) (schedule-remove! victim)))
    (set! victim (schedule-add! s 'victim 1 (noting 'victim)))
    (set! log '())
    (schedule-run! s 'ctx 0.016)
    (null? log)))

;; ---- the tick is not reentrant, and a raise does not wedge it ----
(define raise-ok
  (let ((s (make-schedule)) (after 0))
    (schedule-add! s 'inner 0 (lambda (ctx dt) (schedule-run! s ctx dt)))
    (let ((reentry (refused? 'schedule-run! (lambda () (schedule-run! s 'ctx 0.016)))))
      (let ((s2 (make-schedule)))
        (schedule-add! s2 'boom 0 (lambda (ctx dt) (error 'boom "no")))
        (schedule-add! s2 'later 1 (lambda (ctx dt) (set! after (+ after 1))))
        (and reentry
             (guard (e (#t (eq? (condition-who e) 'boom)))
               (schedule-run! s2 'ctx 0.016) #f)
             (= after 0)                       ; the tick stopped: later did not run
             (guard (e (#t (eq? (condition-who e) 'boom)))
               (schedule-run! s2 'ctx 0.016) #f))))))   ; and the schedule still works

(display (and (report "order" order-ok) (report "stable" stable-ok)
              (report "duplicate" duplicate-ok) (report "mid-tick" mid-tick-ok)
              (report "raise" raise-ok)))
(newline)
