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

;; What several independent sources do to one quantity, as DATA.  An
;; effect names its kind, its source, when it applies and how strongly;
;; a policy per kind says how the payloads combine; `resolve' folds
;; them and hands back both the answer and where each part came from.
;;
;; EVERY ORDERING THE ANSWER DEPENDS ON IS IN THE DATA: the phase list
;; the caller passes, the priority number on each effect, and the order
;; the effects were collected in.  None of it comes from registration
;; order, from a method chain, or from which module loaded first.  Three
;; modules that have never heard of each other can contribute to one
;; number and get the same result whatever order they were loaded in.
;;
;; DISPATCH AND COLLECTION ARE DIFFERENT JOBS.  Picking the one rule
;; that applies is dispatch, and (lng generic) does it.  Unioning what
;; several producers each returned is collection, and `collect-effects'
;; does it, over a list the caller writes out.  There is no implicit
;; method combination here: nothing runs because it happened to be
;; registered.
;;
;; POLICIES ARE NAMES, not procedures.  `sum', `max', `min', `last' and
;; `all' are built in; any other name must be bound by the caller in the
;; same way a machine binds its guards.  So the whole input to `resolve'
;; -- effects, phases, policies -- is a datum: it can be written to a
;; file and replayed, which a table of closures could not.
;;
;; Anything that would let position decide instead is refused by name: a
;; phase listed twice, a kind with two policies, a name bound twice, an
;; effect in a phase nobody asked for, a kind with no policy at all.
(library (lng effect)
  (export make-effect effect? effect-kind effect-source effect-priority
          effect-phase effect-payload
          effect->datum datum->effect
          resolve collect-effects)
  (import (rnrs))

  (define-record-type ($effect $make-effect effect?)
    (fields (immutable kind effect-kind)
            (immutable source effect-source)
            (immutable priority effect-priority)
            (immutable phase effect-phase)
            (immutable payload effect-payload)))

  (define ($fail who what irritants)
    (apply error who what irritants))

  ;; ---- checking what the caller handed over ----
  ;;
  ;; The caller's lists -- effects, phases, policies, bindings -- are
  ;; walked by this FIRST, before any assq or per-item loop touches
  ;; them.  It is the only walk here that terminates on a cyclic list;
  ;; everything after it assumes a finite one and none of it would
  ;; notice a cycle.  The irritant names which argument was bad and
  ;; never carries it: printing a cyclic list is the same endless walk
  ;; that made it a problem.
  ;; Floyd's two pointers, not a table of visited pairs.  A LIST SPINE
  ;; HAS ONE SUCCESSOR PER NODE, and that is the whole reason this
  ;; works: a fast pointer taking two steps to the slow one's one must
  ;; meet it inside any cycle, so a cycle is found in O(n) time and no
  ;; space at all.  The table it replaces was O(n) space and, on this
  ;; runtime, O(n^2) time -- `$eqv-hash' answers a constant for pairs,
  ;; so every visited pair landed in one bucket and each step rescanned
  ;; all of them.  A guard against cyclic input was therefore itself
  ;; quadratic in the length of ordinary, perfectly acyclic input.
  ;;
  ;; DO NOT COPY THIS INTO A WALK OVER A TREE OR A GRAPH.  The
  ;; two-pointer argument needs a single successor; `$walk-datum' below
  ;; descends into both halves of a pair and into every element of a
  ;; vector, so there is no "next" to run ahead along and no meeting
  ;; theorem to appeal to.  That one keeps its table, and keeps the
  ;; cost that comes with it.
  (define ($check-spine who what l)
    (let step ((slow l) (fast l))
      (cond
       ((null? slow) #t)
       ((not (pair? slow))
        ($fail who "this argument is not a proper list" (list what)))
       (else
        ;; advance the fast pointer two, checking the shape as it goes
        (let* ((f1 (cdr fast))
               (f2 (if (pair? f1) (cdr f1) f1)))
          (cond
           ((null? f1) #t)
           ((not (pair? f1))
            ($fail who "this argument is not a proper list" (list what)))
           ((null? f2) #t)
           ((not (pair? f2))
            ($fail who "this argument is not a proper list" (list what)))
           ((eq? f2 (cdr slow))
            ($fail who "this argument contains a cycle" (list what 'cyclic)))
           (else (step (cdr slow) f2))))))))

  ;; A name given twice is a contradiction its writer can see and its
  ;; reader cannot, so it is refused rather than settled by position.
  (define ($check-no-duplicates who what names)
    (let loop ((l names) (seen '()))
      (when (pair? l)
        (when (memq (car l) seen)
          ($fail who "this is given more than once" (list what (car l))))
        (loop (cdr l) (cons (car l) seen)))))

  ;; A datum is what `write' can print and `read' can read back.  The
  ;; three-valued marking distinguishes a node on the CURRENT path (a
  ;; cycle) from one already finished (shared structure, and fine): a
  ;; plain "seen" set would call a diamond a cycle, and no set at all
  ;; is exponential on one.
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

  ;; ---- effects ----

  (define (make-effect kind source priority phase payload)
    (unless (symbol? kind)
      ($fail 'make-effect "a kind is a symbol" (list kind)))
    (unless (symbol? source)
      ($fail 'make-effect "a source is a symbol" (list source)))
    (unless (number? priority)
      ($fail 'make-effect "a priority is a number" (list priority)))
    (unless (symbol? phase)
      ($fail 'make-effect "a phase is a symbol" (list phase)))
    ;; The payload is deliberately unchecked: mid-fight it is often a
    ;; live object, and a library that refused those would be refusing
    ;; the ordinary case to protect a rarer one.  Serialization is
    ;; where it has to be a datum, and effect->datum says so there.
    ($make-effect kind source priority phase payload))

  ;; Nothing here is copied.  Unlike (lng machine), which holds a spec
  ;; for as long as the machine lives and must therefore own it, this
  ;; library reads the effects once and returns; there is no later
  ;; moment at which a mutated payload could make something it stored
  ;; describe a world that has moved on.
  (define (effect->datum e)
    (unless (effect? e)
      ($fail 'effect->datum "not an effect" (list 'effect)))
    (let ((r ($walk-datum (effect-payload e))))
      (when (eq? r 'cycle)
        ($fail 'effect->datum "this payload contains a cycle, so it cannot be written"
               (list (effect-kind e) (effect-source e) 'cyclic)))
      (when (eq? r 'not-a-datum)
        ($fail 'effect->datum "this payload is not a datum, so it cannot be written"
               (list (effect-kind e) (effect-source e)))))
    (list 'effect (effect-kind e) (effect-source e) (effect-priority e)
          (effect-phase e) (effect-payload e)))

  (define (datum->effect d)
    (unless (and (pair? d) (eq? (car d) 'effect))
      ($fail 'datum->effect "not an effect datum" (list 'datum)))
    ($check-spine 'datum->effect 'datum d)
    (unless (= (length d) 6)
      ($fail 'datum->effect "an effect datum is (effect kind source priority phase payload)"
             (list 'datum (length d))))
    (make-effect (cadr d) (caddr d) (cadddr d) (list-ref d 4) (list-ref d 5)))

  ;; ---- policies ----
  ;;
  ;; Named, so the policy table is data.  A caller's own policy is a
  ;; name it binds; the built-in names cannot be rebound, because two
  ;; readings of one name is exactly the ambiguity this library refuses
  ;; everywhere else.

  (define ($numeric name payloads)
    (let loop ((l payloads))
      (when (pair? l)
        (unless (number? (car l))
          ($fail 'resolve "this policy folds numbers" (list name (car l))))
        (loop (cdr l)))))

  (define ($builtin-policy name)
    (case name
      ((sum) (lambda (payloads)
               ($numeric 'sum payloads)
               (let loop ((l payloads) (acc 0))
                 (if (pair? l) (loop (cdr l) (+ acc (car l))) acc))))
      ((max) (lambda (payloads)
               ($numeric 'max payloads)
               (let loop ((l (cdr payloads)) (acc (car payloads)))
                 (if (pair? l)
                     (loop (cdr l) (if (> (car l) acc) (car l) acc))
                     acc))))
      ((min) (lambda (payloads)
               ($numeric 'min payloads)
               (let loop ((l (cdr payloads)) (acc (car payloads)))
                 (if (pair? l)
                     (loop (cdr l) (if (< (car l) acc) (car l) acc))
                     acc))))
      ;; `last' is the policy that can see the fold order, which makes
      ;; it the one a test uses to pin that order down
      ((last) (lambda (payloads)
                (let loop ((l payloads))
                  (if (pair? (cdr l)) (loop (cdr l)) (car l)))))
      ((all) (lambda (payloads) payloads))
      (else #f)))

  (define $builtin-names '(sum max min last all))

  ;; ---- ordering ----
  ;;
  ;; A stable merge sort, written out because this runtime has no sort
  ;; and because stability is the whole point: two effects that agree
  ;; on phase and priority must stay in the order they were collected,
  ;; which is the third and last ordering the data carries.  An
  ;; unstable sort passes every test that only adds numbers up and
  ;; fails exactly the one that can tell.
  (define ($merge a b less?)
    (let loop ((a a) (b b) (acc '()))
      (cond
       ((null? a) (append (reverse acc) b))
       ((null? b) (append (reverse acc) a))
       ;; the right side moves only when it is STRICTLY smaller: on a
       ;; tie the left one goes first, and the left one arrived first
       ((less? (car b) (car a)) (loop a (cdr b) (cons (car b) acc)))
       (else (loop (cdr a) b (cons (car a) acc))))))

  (define ($sort l less?)
    (let ((n (length l)))
      (if (< n 2)
          l
          (let* ((h (quotient n 2))
                 (left (let take ((k h) (x l) (acc '()))
                         (if (= k 0) (reverse acc) (take (- k 1) (cdr x) (cons (car x) acc)))))
                 (right (let drop ((k h) (x l)) (if (= k 0) x (drop (- k 1) (cdr x))))))
            ($merge ($sort left less?) ($sort right less?) less?)))))

  (define ($index-of x l)
    (let loop ((l l) (i 0))
      (cond
       ((not (pair? l)) #f)
       ((eq? (car l) x) i)
       (else (loop (cdr l) (+ i 1))))))

  ;; ---- resolve ----

  (define (resolve effects phases policies . rest)
    (let ((bindings (if (pair? rest) (car rest) '())))
      ($check-spine 'resolve 'effects effects)
      ($check-spine 'resolve 'phases phases)
      ($check-spine 'resolve 'policies policies)
      ($check-spine 'resolve 'bindings bindings)
      (let loop ((l phases))
        (when (pair? l)
          (unless (symbol? (car l))
            ($fail 'resolve "a phase is a symbol" (list (car l))))
          (loop (cdr l))))
      ($check-no-duplicates 'resolve 'phase phases)
      ;; bindings: (name . procedure), no duplicates, and never a name
      ;; the library already answers to
      (let loop ((l bindings))
        (when (pair? l)
          (let ((b (car l)))
            (unless (pair? b)
              ($fail 'resolve "a binding is (name . procedure)" (list 'binding)))
            (unless (symbol? (car b))
              ($fail 'resolve "a policy name is a symbol" (list (car b))))
            (unless (procedure? (cdr b))
              ($fail 'resolve "a policy name is bound to something that is not a procedure"
                     (list (car b))))
            (when (memq (car b) $builtin-names)
              ($fail 'resolve "this policy name is built in and cannot be rebound"
                     (list (car b)))))
          (loop (cdr l))))
      ($check-no-duplicates 'resolve 'binding
                            (let loop ((l bindings) (acc '()))
                              (if (pair? l)
                                  (loop (cdr l) (cons (car (car l)) acc))
                                  (reverse acc))))
      ;; policies: (kind . policy-name), no duplicate kinds, every name
      ;; either built in or bound
      (let loop ((l policies))
        (when (pair? l)
          (let ((p (car l)))
            (unless (pair? p)
              ($fail 'resolve "a policy entry is (kind . policy-name)" (list 'entry)))
            (unless (symbol? (car p))
              ($fail 'resolve "a kind is a symbol" (list (car p))))
            (unless (symbol? (cdr p))
              ($fail 'resolve "a policy is named by a symbol" (list (car p))))
            (unless (or ($builtin-policy (cdr p)) (assq (cdr p) bindings))
              ($fail 'resolve "this policy name is neither built in nor bound"
                     (list (cdr p) (car p) $builtin-names))))
          (loop (cdr l))))
      ($check-no-duplicates 'resolve 'kind
                            (let loop ((l policies) (acc '()))
                              (if (pair? l)
                                  (loop (cdr l) (cons (car (car l)) acc))
                                  (reverse acc))))
      (let loop ((l effects))
        (when (pair? l)
          (let ((e (car l)))
            (unless (effect? e)
              ($fail 'resolve "this is not an effect" (list 'effect)))
            (unless ($index-of (effect-phase e) phases)
              ($fail 'resolve "this effect is in a phase the caller did not ask for"
                     (list (effect-phase e) (effect-kind e) (effect-source e))))
            (unless (assq (effect-kind e) policies)
              ($fail 'resolve "this kind has no policy"
                     (list (effect-kind e) (effect-source e)))))
          (loop (cdr l))))
      ;; phase first, then priority, then -- by the sort being stable --
      ;; the order the caller collected them in
      (let* ((ordered
              ($sort effects
                     (lambda (x y)
                       (let ((px ($index-of (effect-phase x) phases))
                             (py ($index-of (effect-phase y) phases)))
                         (cond
                          ((< px py) #t)
                          ((> px py) #f)
                          (else (< (effect-priority x) (effect-priority y))))))))
             ;; kinds in the order they first contribute, which is the
             ;; order the fold reaches them, not the order they sit in
             ;; the input
             (kinds (let loop ((l ordered) (acc '()))
                      (cond
                       ((not (pair? l)) (reverse acc))
                       ((memq (effect-kind (car l)) acc) (loop (cdr l) acc))
                       (else (loop (cdr l) (cons (effect-kind (car l)) acc)))))))
        (let build ((ks kinds) (res '()) (prov '()))
          (if (not (pair? ks))
              (values (reverse res) (reverse prov))
              (let* ((k (car ks))
                     (mine (let loop ((l ordered) (acc '()))
                             (cond
                              ((not (pair? l)) (reverse acc))
                              ((eq? (effect-kind (car l)) k)
                               (loop (cdr l) (cons (car l) acc)))
                              (else (loop (cdr l) acc)))))
                     (payloads (let loop ((l mine) (acc '()))
                                 (if (pair? l)
                                     (loop (cdr l) (cons (effect-payload (car l)) acc))
                                     (reverse acc))))
                     (rows (let loop ((l mine) (acc '()))
                             (if (pair? l)
                                 (loop (cdr l)
                                       (cons (cons (effect-source (car l))
                                                   (effect-payload (car l)))
                                             acc))
                                 (reverse acc))))
                     (name (cdr (assq k policies)))
                     (fold (or ($builtin-policy name) (cdr (assq name bindings)))))
                (build (cdr ks)
                       (cons (cons k (fold payloads)) res)
                       (cons (cons k rows) prov))))))))

  ;; Call each producer with the same arguments and append what they
  ;; returned, in the order the caller listed them.  That list is the
  ;; whole of the combining this library does: a producer contributes
  ;; because it is named here, not because it was registered somewhere.
  (define (collect-effects producers . args)
    ($check-spine 'collect-effects 'producers producers)
    (let loop ((l producers) (acc '()))
      (if (not (pair? l))
          (reverse acc)
          (let ((g (car l)))
            (unless (procedure? g)
              ($fail 'collect-effects "this producer is not a procedure" (list 'producer)))
            (let ((es (apply g args)))
              ($check-spine 'collect-effects 'result es)
              (let check ((r es) (acc acc))
                (cond
                 ((not (pair? r)) (loop (cdr l) acc))
                 ((effect? (car r)) (check (cdr r) (cons (car r) acc)))
                 (else
                  ($fail 'collect-effects
                         "this producer returned something that is not an effect"
                         (list 'result)))))))))))
