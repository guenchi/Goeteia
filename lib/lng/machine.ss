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

;; A state machine is data: states, an initial state, and transitions
;; whose guards and actions are NAMES.  The procedures behind those
;; names are supplied when the machine is made, so the spec itself is
;; a datum -- it can be written to a file, read back, diffed, drawn.
;;
;; A machine VALUE is immutable.  `machine-step' returns a new machine
;; and the names of the actions that transition asks for; it performs
;; none of them.  Who executes an action, and in what order relative
;; to everything else, is the caller's business and stays visible in
;; the caller's code.
;;
;; NOTHING HERE IS DECIDED BY WRITING ORDER.  That is the point of the
;; library, and it costs more checks than it looks like:
;;   - several transitions may share a (state, event) key only if
;;     every one of them carries a guard.  All the guards are
;;     evaluated and exactly one may hold; two holding at once is a
;;     named error naming the pair, not "the first one wins";
;;   - a clause given twice (two `initial', two `strict') is a named
;;     error, not "the first occurrence wins";
;;   - a name bound twice in the bindings alist is a named error, not
;;     "the first binding wins".
;; Each of those three was a silent first-occurrence rule at some
;; point, and each made the answer depend on where a line sits.
;;
;; The exception to "report at construction" is that guard truth is a
;; run-time fact: ambiguity can only be reported at the step.  Order
;; independence there assumes guards are PURE -- a guard that writes
;; the context can make its neighbours' answers depend on which one
;; ran first, and the library cannot see that.
(library (lng machine)
  (export make-machine machine? machine-state machine-ctx machine-spec
          machine-events machine-transitions machine-step
          machine->datum datum->machine)
  (import (rnrs))

  (define-record-type ($m $make-m machine?)
    (fields (immutable spec $spec)
            (immutable state $state)
            (immutable ctx $ctx)
            (immutable strict $strict)
            (immutable bindings $bindings)))

  ;; The irritants are SPREAD, not wrapped: a caller reading
  ;; `condition-irritants' should find the state, the event and the
  ;; offending rows as three things, not as one list it has to know
  ;; the shape of.  (The one-list convention in this tree predates
  ;; `apply' being available.)
  (define ($fail who what irritants)
    (apply error who what irritants))

  ;; ---- the one walk that survives a hostile input ----
  ;;
  ;; ORDER OF CHECKS, stated once because everything below depends on
  ;; it: `$check-datum' runs FIRST on anything that came from outside.
  ;; It is the only walk here that terminates on a cyclic structure.
  ;; `$proper-list?', `$clause', `$copy' and the spec checks all
  ;; assume a finite acyclic graph and none of them detect a cycle;
  ;; they are safe only because the datum check has already run.
  ;;
  ;; The marks are three-valued on purpose: a node on the CURRENT path
  ;; is a cycle, a node already finished is shared structure and is
  ;; skipped.  A two-valued "seen" set would terminate but call a
  ;; diamond a cycle; no set at all is exponential on a diamond.
  (define ($walk-datum x)
    (let ((seen (make-eq-hashtable)))
      (let walk ((x x))
        (cond
         ((or (pair? x) (vector? x))
          (let ((mark (hashtable-ref seen x 0)))
            (cond
             ((eqv? mark 1) 'cycle)
             ((eqv? mark 2) #t)
             (else
              (hashtable-set! seen x 1)
              (let ((r (if (pair? x)
                           (let ((a (walk (car x))))
                             (if (eq? a #t) (walk (cdr x)) a))
                           (let loop ((i 0))
                             (if (= i (vector-length x))
                                 #t
                                 (let ((r (walk (vector-ref x i))))
                                   (if (eq? r #t) (loop (+ i 1)) r)))))))
                (hashtable-set! seen x 2)
                r)))))
         ((null? x) #t)
         ((symbol? x) #t)
         ((string? x) #t)
         ((char? x) #t)
         ((boolean? x) #t)
         ((number? x) #t)
         ((bytevector? x) #t)
         (else 'not-a-datum)))))

  ;; The irritant names WHICH value failed and never carries the value
  ;; itself: printing a cyclic structure is the same non-terminating
  ;; walk that produced the error, and an error that hangs while being
  ;; reported is worse than the error it was reporting.
  (define ($check-datum who what x)
    (let ((r ($walk-datum x)))
      (cond
       ((eq? r 'cycle)
        ($fail who "this value contains a cycle, so it cannot be written"
               (list what 'cyclic)))
       ((eq? r 'not-a-datum)
        ($fail who "this value is not a datum, so it cannot be written"
               (list what 'not-a-datum)))
       (else #t))))

  ;; Deep, because a shallow copy of a spec is not a copy at all: the
  ;; caller still holds every ROW, and `(set-car! (car rows) 'b)' on
  ;; what an accessor handed out would rewrite the machine's own
  ;; transition.  Strings and bytevectors are copied too -- they are
  ;; mutable leaves, and copying the spine while sharing them leaves
  ;; the same hole one level down.  Pairs and vectors are memoized so
  ;; shared structure stays linear instead of being expanded once per
  ;; path that reaches it.
  (define ($copy x)
    (let ((memo (make-eq-hashtable)))
      (let cp ((x x))
        (cond
         ((pair? x)
          (let ((hit (hashtable-ref memo x #f)))
            (or hit
                (let ((p (cons (cp (car x)) (cp (cdr x)))))
                  (hashtable-set! memo x p)
                  p))))
         ((vector? x)
          (let ((hit (hashtable-ref memo x #f)))
            (or hit
                (let* ((n (vector-length x)) (v (make-vector n)))
                  (hashtable-set! memo x v)
                  (let loop ((i 0))
                    (if (= i n)
                        v
                        (begin (vector-set! v i (cp (vector-ref x i)))
                               (loop (+ i 1)))))))))
         ((string? x) (string-copy x))
         ((bytevector? x)
          (let* ((n (bytevector-length x)) (b (make-bytevector n)))
            (let loop ((i 0))
              (if (= i n)
                  b
                  (begin (bytevector-u8-set! b i (bytevector-u8-ref x i))
                         (loop (+ i 1)))))))
         (else x)))))

  (define ($proper-list? x)
    (let loop ((l x))
      (cond
       ((null? l) #t)
       ((pair? l) (loop (cdr l)))
       (else #f))))

  ;; The spine check for arguments that are NOT data: a bindings alist
  ;; holds procedures, so it can never go through `$check-datum', and
  ;; the option list is walked before the datum check reaches it.
  ;; Both were therefore still walked by `$proper-list?' and `$clause'
  ;; first -- which is to say the note above about the datum check
  ;; running first was true of the spec and false of these two, and a
  ;; cyclic list of either hung the compiler with no output at all.
  ;; This is the door those two arguments get instead.
  (define ($check-spine who what l)
    (let ((seen (make-eq-hashtable)))
      (let loop ((l l))
        (cond
         ((null? l) #t)
         ((not (pair? l))
          ($fail who "this argument is not a proper list" (list what)))
         ((hashtable-ref seen l #f)
          ($fail who "this argument contains a cycle" (list what 'cyclic)))
         (else
          (hashtable-set! seen l #t)
          (loop (cdr l)))))))

  (define ($clause l key)
    (let loop ((cs l))
      (cond
       ((not (pair? cs)) #f)
       ((and (pair? (car cs)) (eq? (car (car cs)) key)) (car cs))
       (else (loop (cdr cs))))))

  (define ($clause-value c)
    (and (pair? c) (pair? (cdr c)) (cadr c)))

  ;; A key given twice is a contradiction the writer can see and the
  ;; reader cannot: `((strict #f) (strict #t))' would otherwise decide
  ;; how hard the spec is checked by which line came first.
  (define ($check-no-dup-clauses who what l)
    (let loop ((l l) (seen '()))
      (if (not (pair? l))
          #t
          (let ((c (car l)))
            (if (and (pair? c) (symbol? (car c)))
                (begin
                  (when (memq (car c) seen)
                    ($fail who "this is given more than once" (list what (car c))))
                  (loop (cdr l) (cons (car c) seen)))
                (loop (cdr l) seen))))))

  ;; Validated as a whole before any assq touches it: an entry that is
  ;; not a pair makes assq trap in the host, outside every `guard' the
  ;; caller could have written, and whether it traps at all depends on
  ;; whether an earlier entry happened to match first.
  (define ($check-bindings who bindings)
    ($check-spine who 'bindings bindings)
    (let loop ((l bindings) (seen '()))
      (when (pair? l)
        (let ((b (car l)))
          (unless (and (pair? b) (symbol? (car b)) (procedure? (cdr b)))
            ($fail who "a binding is not (name . procedure)"
                   (list (if (and (pair? b) (symbol? (car b))) (car b) 'entry))))
          (when (memq (car b) seen)
            ($fail who "a name is bound more than once" (list (car b))))
          (loop (cdr l) (cons (car b) seen))))))

  ;; transition = (from event to [guard] [action])
  (define ($t-from t) (car t))
  (define ($t-event t) (cadr t))
  (define ($t-to t) (caddr t))
  (define ($t-guard t) (if (pair? (cdddr t)) (car (cdddr t)) #f))
  (define ($t-action t)
    (if (and (pair? (cdddr t)) (pair? (cdr (cdddr t))))
        (car (cdr (cdddr t)))
        #f))

  (define ($well-formed-transition? t)
    (and (pair? t)
         ($proper-list? t)
         (let ((n (length t)))
           (and (>= n 3) (<= n 5)
                (symbol? (car t)) (symbol? (cadr t)) (symbol? (caddr t))
                (let ((g ($t-guard t)))
                  (or (not g) (symbol? g)))
                (let ((a ($t-action t)))
                  (or (not a) (symbol? a)))))))

  ;; ---- construction ----

  (define ($check-spec who spec bindings strict)
    ($check-datum who 'spec spec)
    (unless ($proper-list? spec)
      ($fail who "a spec is a list of clauses" (list 'spec)))
    ($check-no-dup-clauses who 'spec-clause spec)
    (unless (boolean? strict)
      ($fail who "strict is #t or #f" (list 'strict)))
    (let ((states-c ($clause spec 'states))
          (initial-c ($clause spec 'initial))
          (trans-c ($clause spec 'transitions)))
      (unless (and states-c ($clause-value states-c)
                   ($proper-list? ($clause-value states-c)))
        ($fail who "spec needs a (states (s ...)) clause" (list 'states)))
      (unless (and initial-c (pair? (cdr initial-c)))
        ($fail who "spec needs an (initial s) clause" (list 'initial)))
      (unless (and trans-c (pair? (cdr trans-c))
                   ($proper-list? (cadr trans-c)))
        ($fail who "spec needs a (transitions (...)) clause" (list 'transitions)))
      (let ((states (cadr states-c))
            (initial (cadr initial-c))
            (ts (cadr trans-c)))
        ;; a state is a name -- in `states' and in `initial' as much as
        ;; in a transition.  The deep copy gives every non-symbol label
        ;; a fresh identity, so `memq' would afterwards not find the
        ;; state the machine was just built with.
        (let loop ((l states))
          (when (pair? l)
            (unless (symbol? (car l))
              ($fail who "a state is not a symbol" (list (car l))))
            (loop (cdr l))))
        (unless (symbol? initial)
          ($fail who "the initial state is not a symbol" (list initial)))
        (unless (memq initial states)
          ($fail who "the initial state is not one of the states"
                 (list initial states)))
        (let loop ((l ts))
          (when (pair? l)
            (let ((t (car l)))
              (unless ($well-formed-transition? t)
                ($fail who "a transition is not (from event to [guard] [action])"
                       (list ($copy t))))
              (unless (memq ($t-from t) states)
                ($fail who "a transition leaves from an unknown state"
                       (list ($t-from t) states)))
              (unless (memq ($t-to t) states)
                ($fail who "a transition leads to an unknown state"
                       (list ($t-to t) states)))
              (let ((g ($t-guard t)))
                (when (and g (not (assq g bindings)))
                  ($fail who "a guard name has no binding" (list g ($copy t)))))
              (loop (cdr l)))))
        ;; several transitions on one key are allowed only when every
        ;; one of them is guarded: two unguarded ones would make the
        ;; answer depend on where they sit in the file
        (let outer ((l ts))
          (when (pair? l)
            (let* ((t (car l))
                   (same (let inner ((r ts) (acc '()))
                           (cond
                            ((not (pair? r)) (reverse acc))
                            ((and (eq? ($t-from (car r)) ($t-from t))
                                  (eq? ($t-event (car r)) ($t-event t)))
                             (inner (cdr r) (cons (car r) acc)))
                            (else (inner (cdr r) acc))))))
              (when (and (> (length same) 1)
                         (let any ((s same))
                           (and (pair? s)
                                (or (not ($t-guard (car s))) (any (cdr s))))))
                ($fail who "two transitions share a (state event) key without guards"
                       (list ($t-from t) ($t-event t) ($copy same)))))
            (outer (cdr l))))
        ;; reachability is structural: a guard that can never hold
        ;; still counts as an edge, and the library does not pretend
        ;; to decide satisfiability
        (when strict
          (let* ((reached
                  (let grow ((frontier (list initial)) (seen (list initial)))
                    (if (not (pair? frontier))
                        seen
                        (let step ((l ts) (front '()) (seen seen))
                          (if (pair? l)
                              (let ((t (car l)))
                                (if (and (eq? ($t-from t) (car frontier))
                                         (not (memq ($t-to t) seen)))
                                    (step (cdr l) (cons ($t-to t) front)
                                          (cons ($t-to t) seen))
                                    (step (cdr l) front seen)))
                              (grow (append (cdr frontier) front) seen))))))
                 (lost (let loop ((l states) (acc '()))
                         (cond
                          ((not (pair? l)) (reverse acc))
                          ((memq (car l) reached) (loop (cdr l) acc))
                          (else (loop (cdr l) (cons (car l) acc)))))))
            (unless (null? lost)
              ($fail who "these states cannot be reached from the initial state"
                     (list lost initial))))))))

  ;; Every option this library understands.  A spec may carry clauses
  ;; the library does not know -- it is the user's data, it round
  ;; trips, and `(metadata ...)' beside it is none of our business --
  ;; but an OPTION is an instruction to the library, and an
  ;; instruction it does not recognize has no reading under which it
  ;; still applies.  It is a misspelling, and saying so beats
  ;; ignoring it.
  (define $known-options '(strict))

  (define ($check-options who opts)
    ($check-spine who 'options opts)
    ($check-datum who 'options opts)
    ($check-no-dup-clauses who 'option opts)
    (let loop ((l opts))
      (when (pair? l)
        (let ((c (car l)))
          (unless (and (pair? c) (symbol? (car c)))
            ($fail who "an option is not (name value)" (list 'option)))
          (unless (memq (car c) $known-options)
            ($fail who "this option is not one this library understands"
                   (list (car c) $known-options)))
          ;; `(strict)' is not "strict, unspecified": it is a line
          ;; whose writer meant something and did not say it.  And
          ;; `(strict #f extra)' is not "strict #f with a comment":
          ;; the extra element is either a second value nobody reads
          ;; or a typo, and both readings are worth refusing.  An
          ;; option is exactly (name value).
          (unless (and (pair? (cdr c)) (null? (cddr c)))
            ($fail who "an option is exactly (name value)" (list (car c))))
          (loop (cdr l))))))

  (define ($opt who opts key default)
    ($check-options who opts)
    (let ((c ($clause opts key)))
      (if c (cadr c) default)))

  ;; the alist itself is copied so a caller cannot rebind a name under
  ;; a live machine; the procedures in it are shared, as they must be
  (define ($copy-bindings bs)
    (let loop ((l bs) (acc '()))
      (if (pair? l)
          (loop (cdr l) (cons (cons (car (car l)) (cdr (car l))) acc))
          (reverse acc))))

  (define (make-machine spec bindings . rest)
    (let* ((ctx (if (pair? rest) (car rest) '()))
           (opts (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) '()))
           (strict ($opt 'make-machine opts 'strict #t)))
      ($check-bindings 'make-machine bindings)
      ($check-datum 'make-machine 'ctx ctx)
      ($check-spec 'make-machine spec bindings strict)
      ($make-m ($copy spec) (cadr ($clause spec 'initial)) ctx strict
               ($copy-bindings bindings))))

  ;; ---- reading a machine ----

  (define (machine-state m) ($state m))
  (define (machine-ctx m) ($ctx m))
  (define (machine-spec m) ($copy ($spec m)))
  (define (machine-transitions m)
    ($copy (cadr ($clause ($spec m) 'transitions))))

  ;; Structurally available events: what the spec offers from here,
  ;; without evaluating any guard.  A disabled button is a question
  ;; about shape, and asking it must not run the caller's predicates.
  (define (machine-events m)
    (let loop ((l (cadr ($clause ($spec m) 'transitions))) (acc '()))
      (cond
       ((not (pair? l)) (reverse acc))
       ((and (eq? ($t-from (car l)) ($state m))
             (not (memq ($t-event (car l)) acc)))
        (loop (cdr l) (cons ($t-event (car l)) acc)))
       (else (loop (cdr l) acc)))))

  ;; ---- stepping ----

  (define ($unknown-is-error? m)
    (let ((c ($clause ($spec m) 'on-unknown)))
      (and c (pair? (cdr c)) (eq? (cadr c) 'error))))

  (define ($candidates m event)
    (let loop ((l (cadr ($clause ($spec m) 'transitions))) (acc '()))
      (cond
       ((not (pair? l)) (reverse acc))
       ((and (eq? ($t-from (car l)) ($state m))
             (eq? ($t-event (car l)) event))
        (loop (cdr l) (cons (car l) acc)))
       (else (loop (cdr l) acc)))))

  (define ($guard-holds? m t ctx)
    (let ((g ($t-guard t)))
      (if (not g)
          #t
          (let ((b (assq g ($bindings m))))
            (unless b
              ($fail 'machine-step "a guard name has no binding"
                     (list g ($copy t))))
            (if ((cdr b) ctx) #t #f)))))

  (define ($same-ctx m ctx)
    (if (eq? ctx ($ctx m))
        m
        ($make-m ($spec m) ($state m) ctx ($strict m) ($bindings m))))

  (define (machine-step m event . rest)
    (unless (machine? m)
      ($fail 'machine-step "not a machine" (list 'machine)))
    (let ((ctx (if (pair? rest) (car rest) ($ctx m))))
      (when (pair? rest)
        ($check-datum 'machine-step 'ctx ctx))
      (let* ((cands ($candidates m event))
             (live (let loop ((l cands) (acc '()))
                     (cond
                      ((not (pair? l)) (reverse acc))
                      (($guard-holds? m (car l) ctx)
                       (loop (cdr l) (cons (car l) acc)))
                      (else (loop (cdr l) acc))))))
        (cond
         ((> (length live) 1)
          ;; every guard was evaluated; more than one holding is a
          ;; statement about the model, not something to break by
          ;; picking a line number.  The rows go out COPIED: an
          ;; irritant is a diagnostic, and a diagnostic that hands
          ;; back a handle on the machine's own spec is a second way
          ;; in.
          ($fail 'machine-step "more than one guard holds for this event"
                 (list ($state m) event ($copy live))))
         ((null? live)
          (if ($unknown-is-error? m)
              ($fail 'machine-step "no transition for this event"
                     (list ($state m) event (machine-events m)))
              (values ($same-ctx m ctx) '())))
         (else
          (let* ((t (car live))
                 (action ($t-action t)))
            (values ($make-m ($spec m) ($t-to t) ctx ($strict m) ($bindings m))
                    (if action (list action) '()))))))))

  ;; ---- the datum ----
  ;; Everything but the bindings: those are procedures, they are named
  ;; in the spec, and the reader supplies them again.  The strictness
  ;; travels too, so a machine assembled from fragments reads back as
  ;; the machine that was written rather than being re-judged.

  (define (machine->datum m)
    (unless (machine? m)
      ($fail 'machine->datum "not a machine" (list 'machine)))
    ($check-datum 'machine->datum 'ctx ($ctx m))
    (list 'machine
          (list 'spec ($copy ($spec m)))
          (list 'state ($state m))
          (list 'ctx ($ctx m))
          (list 'strict ($strict m))))

  (define (datum->machine d bindings)
    ($check-datum 'datum->machine 'datum d)
    (unless (and (pair? d) ($proper-list? d) (eq? (car d) 'machine))
      ($fail 'datum->machine "not a machine datum" (list 'datum)))
    ($check-bindings 'datum->machine bindings)
    ($check-no-dup-clauses 'datum->machine 'field (cdr d))
    (let ((spec-c ($clause (cdr d) 'spec))
          (state-c ($clause (cdr d) 'state))
          (ctx-c ($clause (cdr d) 'ctx))
          (strict-c ($clause (cdr d) 'strict)))
      ;; each field must actually carry its value: `(spec)' is a
      ;; clause that is present and empty, and reading it with cadr is
      ;; how a malformed file turns into a trap instead of a diagnosis
      (let loop ((cs (list (cons 'spec spec-c) (cons 'state state-c)
                           (cons 'ctx ctx-c))))
        (when (pair? cs)
          (let ((name (car (car cs))) (c (cdr (car cs))))
            (unless (and c (pair? (cdr c)))
              ($fail 'datum->machine "a machine datum needs spec, state and ctx"
                     (list name)))
            (loop (cdr cs)))))
      (when (and strict-c (not (pair? (cdr strict-c))))
        ($fail 'datum->machine "the strict field carries no value" (list 'strict)))
      (let* ((spec (cadr spec-c))
             (state (cadr state-c))
             (ctx (cadr ctx-c))
             (strict (if strict-c (cadr strict-c) #t)))
        ;; the same checks make-machine runs: a datum is an input like
        ;; any other, and the fact that this library wrote it once
        ;; says nothing about the copy that came back
        ($check-datum 'datum->machine 'ctx ctx)
        ($check-spec 'datum->machine spec bindings strict)
        (unless (memq state (cadr ($clause spec 'states)))
          ($fail 'datum->machine "the recorded state is not one of the states"
                 (list state (cadr ($clause spec 'states)))))
        ($make-m ($copy spec) state ctx strict ($copy-bindings bindings))))))
