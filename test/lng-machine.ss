;; expect: #t
;; (lng machine): a state machine is DATA -- states, an initial state
;; and transitions (from event to [guard] [action]) where guards and
;; actions are NAMES bound to procedures when the machine is made, so
;; the spec can be written, read back and kept in a file.  A machine
;; value is immutable: `machine-step' returns a new machine and the
;; names of the actions to perform; it performs nothing itself.
;; Guards on the same (state, event) are all evaluated: exactly one
;; may hold.  Design: archive/goeteia-lng-design.md §2, r2-5/6, r3-4/5/6.
(import (rnrs) (web sexpr) (lng machine))

(define (refused? who thunk)
  (guard (e (#t (and (error? e) (eq? (condition-who e) who))))
    (thunk) #f))
(define (report name ok) (unless ok (display "  FAIL ") (display name) (newline)) ok)

(define door-spec
  '((states (closed open locked))
    (initial closed)
    (transitions
     ((closed push open) (open push closed)
      (closed lock locked has-key)             ; guard: has-key
      (closed lock closed no-key ring-alarm)   ; guard: no-key, action: ring-alarm
      (locked unlock closed has-key)))))
(define bindings
  (list (cons 'has-key (lambda (ctx) (memq 'key ctx)))
        (cons 'no-key (lambda (ctx) (not (memq 'key ctx))))))

(define m0 (make-machine door-spec bindings '(key)))

;; ---- construction refuses a broken spec, by name ----
(define (spec-with . edits) (fold-left (lambda (s e) (e s)) door-spec edits))
(define construct-ok
  (and (refused? 'make-machine (lambda () (make-machine '((states (a b)) (initial a) (transitions ((a go c)))) '())))         ; unknown state c
       (refused? 'make-machine (lambda () (make-machine '((states (a b)) (initial z) (transitions ((a go b)))) '())))         ; initial not a state
       ;; the same three with reachability switched off: each check must stand on its own,
       ;; not on the unreachable-state check happening to fire first
       (refused? 'make-machine (lambda () (make-machine '((states (a b)) (initial z) (transitions ((a go b)))) '() #f '((strict #f)))))
       (refused? 'make-machine (lambda () (make-machine '((states (a b)) (initial a) (transitions ((a go c)))) '() #f '((strict #f)))))
       (refused? 'make-machine (lambda () (make-machine '((states (a b)) (initial a) (transitions ((z go b)))) '() #f '((strict #f)))))  ; unknown FROM state
       (refused? 'make-machine (lambda () (make-machine '((states (a b)) (initial a) (transitions ((a go b) (a go a)))) '()))) ; duplicate (from event) without guards
       (refused? 'make-machine (lambda () (make-machine '((states (a b c)) (initial a) (transitions ((a go b)))) '())))       ; c unreachable (strict by default)
       (machine? (make-machine '((states (a b c)) (initial a) (transitions ((a go b)))) '() #f '((strict #f))))                ; ...unless told not to care
       (refused? 'make-machine (lambda () (make-machine door-spec '() '(key))))                                                ; a guard name with no binding
       (refused? 'make-machine (lambda () (make-machine door-spec bindings (lambda () 'not-a-datum))))))                         ; ctx must be a datum

;; ---- a guard NAME is bound to a procedure, or the machine is not made ----
;; Guards are called by the machine, so each needs a procedure; an
;; action is only a name handed back to the caller, which is why m0
;; above binds no ring-alarm.  A guard binding that is not a procedure
;; is a spelling mistake caught here, not on the first step.
(define binding-ok
  (and (refused? 'make-machine (lambda () (make-machine '((states (a b)) (initial a) (transitions ((a go b ok)))) '((ok . 42)))))                                ; a binding that is not a procedure
       (refused? 'make-machine (lambda () (make-machine '((states (a b)) (initial a) (transitions ((a go b (guard ok))))) '())))))                              ; a name slot that is not a symbol

;; ---- what the accessors hand out is not a handle on the machine ----
;; Mutating a transition row obtained from machine-transitions must not
;; change what the machine does; spec rows are copied out, not shared.
(define copy-out-ok
  (let* ((m (make-machine '((states (a b)) (initial a) (transitions ((a go b)))) '()))
         (rows (machine-transitions m)))
    (set-car! (car rows) 'b)                          ; try to turn (a go b) into (b go b)
    (let-values (((m1 acts) (machine-step m 'go)))
      (eq? (machine-state m1) 'b))))                  ; the machine still has (a go b)

;; ---- datum->machine refuses a malformed datum by name, not by crashing ----
(define malformed-ok
  (and (refused? 'datum->machine (lambda () (datum->machine '(machine (spec) (state a) (ctx ())) '())))
       (refused? 'datum->machine (lambda () (datum->machine '(machine (spec ((states (a b)) (initial a) (transitions ((a go . b))))) (state a) (ctx ())) '())))
       (refused? 'datum->machine (lambda () (datum->machine 'not-a-machine '())))))

;; ---- the rest of a spec's shape is checked too, by name ----
(define shape-ok
  (and (refused? 'make-machine (lambda () (make-machine '((states (a "b")) (initial a) (transitions ((a go a)))) '())))            ; a state that is not a symbol
       (refused? 'make-machine (lambda () (make-machine '((states (a b)) (initial a) (initial b) (transitions ((a go b)))) '())))  ; a clause given twice
       (refused? 'make-machine (lambda () (make-machine '((states (a b)) (initial a) (transitions ((a go b)))) '(oops))))         ; a bindings entry that is not a pair
       (refused? 'make-machine (lambda () (make-machine '((states (a b)) (initial a) (transitions ((a go b)))) '() #f '((strict)))))))  ; an option without a value

;; ---- "written where" never decides anything: duplicates are refused, not resolved ----
(define no-first-wins-ok
  (and (refused? 'make-machine (lambda () (make-machine '((states (a b)) (initial a) (transitions ((a go b g))))
                                                       (list (cons 'g (lambda (c) #t)) (cons 'g (lambda (c) #f))))))   ; one name bound twice
       (refused? 'make-machine (lambda () (make-machine '((states (a b)) (initial a) (transitions ((a go b)))) '() #f '((strict #f) (strict #t)))))
       (refused? 'make-machine (lambda () (make-machine '((states (a b)) (initial a) (transitions ((a go b))) (transitions ((a go b)))) '())))))   ; a clause given twice, non-adjacent

;; ---- everything that goes in is a datum, and comes back out as one ----
(define datum-ok
  (and (refused? 'make-machine (lambda () (make-machine (cons (list 'metadata (lambda () #t)) '((states (a)) (initial a) (transitions ()))) '())))  ; a procedure inside the spec
       (refused? 'make-machine (lambda () (make-machine '((states (a)) (initial a) (transitions ())) '() #f (list (list 'strict (lambda () #t))))))
       (machine? (make-machine '((states (a)) (initial a) (transitions ())) '() (make-bytevector 2 0)))   ; a bytevector is a datum
       (let* ((m (make-machine '((states (a)) (initial a) (transitions ()) (note "before")) '()))
              (sp (machine-spec m)))
         (string-set! (cadr (assq 'note sp)) 0 #\z)                        ; scribble on the copy we were handed
         (string=? (cadr (assq 'note (machine-spec m))) "before"))         ; the machine's own string is untouched
       (let ((cyc (list 1 2)))
         (set-cdr! (cdr cyc) cyc)                                            ; a cycle: refused by name, never walked forever
         (refused? 'make-machine (lambda () (make-machine '((states (a)) (initial a) (transitions ())) '() cyc))))))

;; ---- the other two arguments are walked as carefully as the datums ----
;; Options and bindings are not datums (bindings hold procedures), but a
;; cycle in either must still be refused by name before anything walks it,
;; and an option the library does not know is a spelling mistake, not a no-op.
(define argument-walk-ok
  (let ((spec '((states (a)) (initial a) (transitions ())))
        (cyc-opts (list (list 'strict #f)))
        (cyc-bind (list (cons 'g (lambda (c) #t)))))
    (set-cdr! cyc-opts cyc-opts)
    (set-cdr! cyc-bind cyc-bind)
    (and (refused? 'make-machine (lambda () (make-machine spec '() #f cyc-opts)))
         (refused? 'make-machine (lambda () (make-machine spec cyc-bind)))
         (refused? 'make-machine (lambda () (make-machine spec '() #f '((other 1)))))     ; an option nobody defined
         (refused? 'make-machine (lambda () (make-machine spec '() #f '((other)))))
         (refused? 'make-machine (lambda () (make-machine spec '() #f '((strict #f extra)))))   ; an option is exactly (name value)
         (refused? 'make-machine (lambda () (make-machine spec '() #f '((strict #f . tail))))))))

;; ---- what an error carries is a copy too ----
;; The ambiguity error lists the transitions that were all true; mutating
;; a row out of a caught condition must not reach into the machine.
(define irritant-copy-ok
  (let* ((m (make-machine '((states (a b c)) (initial a) (transitions ((a go b yes) (a go c yes) (b back a) (c back a))))
                          (list (cons 'yes (lambda (ctx) #t)))))
         (rows (guard (e (#t (let loop ((l (condition-irritants e)))
                               (cond ((null? l) '())
                                     ((and (pair? (car l)) (pair? (caar l))) (car l))
                                     (else (loop (cdr l)))))))
                 (machine-step m 'go) '())))
    (and (pair? rows)
         (begin (set-car! (car rows) 'zzz) #t)
         (refused? 'machine-step (lambda () (machine-step m 'go))))))   ; still ambiguous: the machine still has both rows

;; ---- step is pure and returns the actions by name ----
(define step-ok
  (let-values (((m1 acts) (machine-step m0 'push)))
    (and (eq? (machine-state m0) 'closed)          ; the old value is untouched
         (eq? (machine-state m1) 'open)
         (null? acts)
         (let-values (((m2 acts2) (machine-step m1 'push)))
           (and (eq? (machine-state m2) 'closed) (null? acts2))))))

;; ---- guards: all evaluated, exactly one may hold, position is not a factor ----
(define guard-ok
  (and (let-values (((m1 acts) (machine-step m0 'lock)))                 ; ctx has the key: has-key holds
         (and (eq? (machine-state m1) 'locked) (null? acts)))
       (let-values (((m1 acts) (machine-step m0 'lock '())))             ; no key: the SECOND transition holds
         (and (eq? (machine-state m1) 'closed) (equal? acts '(ring-alarm))))
       ;; two UNGUARDED transitions on one key cannot both be right: refused at construction
       (refused? 'make-machine (lambda () (make-machine '((states (a b c)) (initial a)
                                                         (transitions ((a go b) (a go c))))
                                                       '() #f '((strict #f)))))))
(define guard-ambiguity-ok
  (let ((m (make-machine '((states (a b c)) (initial a)
                           (transitions ((a go b yes) (a go c yes-too))))
                         (list (cons 'yes (lambda (ctx) #t)) (cons 'yes-too (lambda (ctx) #t))) #f)))
    (and (refused? 'machine-step (lambda () (machine-step m 'go)))
         (eq? (machine-state m) 'a))))                                  ; nothing moved

;; ---- an event with no transition: silent by default, an error on request ----
(define unknown-ok
  (and (let-values (((m1 acts) (machine-step m0 'unlock)))              ; closed has no unlock
         (and (eq? m1 m0) (null? acts)))
       (let ((strictm (make-machine (append door-spec '((on-unknown error))) bindings '(key))))
         (refused? 'machine-step (lambda () (machine-step strictm 'unlock))))))

;; ---- what the machine can do from here, structurally ----
(define events-ok
  (let ((evs (machine-events m0)))
    (and (= (length evs) 2) (memq 'push evs) (memq 'lock evs) #t
         (let-values (((m1 acts) (machine-step m0 'lock)))
           (equal? (machine-events m1) '(unlock))))))

;; ---- ctx: given at construction, replaceable per step, retained ----
(define ctx-ok
  (let-values (((m1 acts) (machine-step m0 'lock '())))                 ; the step's ctx replaces the machine's
    (and (equal? acts '(ring-alarm))
         (equal? (machine-ctx m1) '())                                  ; ...and is retained afterwards
         (let-values (((m2 acts2) (machine-step m1 'lock)))              ; no ctx given: the retained one is used
           (equal? acts2 '(ring-alarm))))))

;; ---- datum round trip: write, read, rebuild; bindings by name ----
(define roundtrip-ok
  (let-values (((m1 acts) (machine-step m0 'lock)))
    (let* ((d (machine->datum m1))
           (text (sexpr->string d))              ; the transport codec: what a save file or a wire would carry
           (back (string->sexpr text))
           (m2 (datum->machine back bindings)))
      (and (equal? d back)
           (eq? (machine-state m2) 'locked)
           (equal? (machine-events m2) (machine-events m1))
           (equal? (machine-ctx m2) '(key))
           (refused? 'datum->machine (lambda () (datum->machine back '())))       ; the names need their bindings
           (let-values (((m3 acts3) (machine-step m2 'unlock)))
             (eq? (machine-state m3) 'closed))))))

;; ---- enumeration for diagnostics ----
(define enumerate-ok
  (= (length (machine-transitions m0)) 5))

(let ((all (list (report "construct" construct-ok) (report "step" step-ok) (report "guard" guard-ok)
                 (report "guard-ambiguity" guard-ambiguity-ok) (report "unknown" unknown-ok)
                 (report "events" events-ok) (report "ctx" ctx-ok) (report "roundtrip" roundtrip-ok)
                 (report "enumerate" enumerate-ok) (report "binding" binding-ok)
                 (report "copy-out" copy-out-ok) (report "malformed" malformed-ok)
                 (report "shape" shape-ok) (report "irritant-copy" irritant-copy-ok)
                 (report "no-first-wins" no-first-wins-ok) (report "datum" datum-ok)
                 (report "argument-walk" argument-walk-ok))))
  (let loop ((l all)) (or (null? l) (and (car l) (loop (cdr l))))))
