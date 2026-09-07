;; expect: #t
;; (lng pred) and (lng generic): multi-argument dispatch whose conflicts
;; are found before the first call, not decided by registration order.
;;
;; Tag mode: every argument position has a CLASSIFIER, a procedure
;; from a value to a symbol out of a declared finite set of tags, with
;; a subtag lattice (paladin < warrior).  A handler's signature is a
;; tuple of tags or `_'.  Because the tag domain is finite, every tuple
;; two signatures can both match is enumerable, and each such tuple
;; must have exactly one dominating signature -- checked on EVERY
;; commit, the first included: each change is a transaction, validated
;; as a whole before anything is installed, committed atomically, the
;; previous configuration untouched on failure.
;;
;; Predicate mode is the escape hatch for open-ended predicates; there
;; ambiguity can only be reported at call time.
;;
;; Design: archive/goeteia-lng-design.md (r4).  Every error is named
;; after the operation that refuses (condition-who).
(import (rnrs) (lng pred) (lng generic))

(define (refused? who thunk)
  (guard (e (#t (and (error? e) (eq? (condition-who e) who))))
    (thunk) #f))
(define (report name ok) (unless ok (display "  FAIL ") (display name) (newline)) ok)

;; ---- classifiers: a finite tag domain, a lattice, no cycles ----
(define (skill-of x) (car x))              ; a skill is (kind . power)
(define (job-of x) (cdr x))                ; a target is (name . job)
(define skill-kind (define-classifier 'skill-kind skill-of '(fire ice arcane)))
(define job (define-classifier 'job job-of '(warrior paladin mage healer)))
(declare-subtag! job 'paladin 'warrior)
(declare-subtag! job 'paladin 'healer)     ; a paladin is both: a diamond below warrior and healer

(define pred-ok
  (and (classifier? job)
       (eq? (classify job '(bob . paladin)) 'paladin)
       (subtag? job 'paladin 'warrior)                 ; declared
       (subtag? job 'paladin 'paladin)                 ; reflexive
       (not (subtag? job 'warrior 'paladin))
       (let ((d (descendants job 'warrior)))              ; the closure: itself and paladin, nothing else
         (and (= (length d) 2) (memq 'warrior d) (memq 'paladin d) #t))
       ;; a tag outside the domain, a cycle, and an unknown tag in a relation are refused by name
       (refused? 'classify (lambda () (classify job '(x . rogue))))
       (refused? 'declare-subtag! (lambda () (declare-subtag! job 'warrior 'paladin)))   ; would close a cycle
       (refused? 'declare-subtag! (lambda () (declare-subtag! job 'rogue 'warrior)))))

;; ---- a two-argument generic: damage by skill kind and target job ----
(define damage (make-generic 'damage 2 (classifiers skill-kind job)))
(add-handlers! damage
  (list (cons '(fire mage)   (lambda (s t) 'fire-on-mage))
        (cons '(fire _)      (lambda (s t) 'fire-on-anyone))
        (cons '(_ _)         (lambda (s t) 'plain))))
(define dispatch-ok
  (and (eq? (damage '(fire . 3) '(al . mage)) 'fire-on-mage)
       (eq? (damage '(fire . 3) '(bo . warrior)) 'fire-on-anyone)
       (eq? (damage '(ice . 3) '(al . mage)) 'plain)
       (eq? (damage '(arcane . 1) '(cy . healer)) 'plain)
       ;; the trace names the tuple and the winner without calling it
       (equal? (dispatch-trace damage (list '(fire . 3) '(al . mage)))
               '((fire mage) ((fire mage) (fire _) (_ _)) (fire mage)))
       ;; transitive chain: paladin < warrior; signatures (warrior) and (paladin)
       ;; both match a paladin and the chain decides; a plain warrior sees only one
       (let* ((k3 (define-classifier 'k3 (lambda (x) x) '(a b c)))
              (chain (begin (declare-subtag! k3 'b 'a) (declare-subtag! k3 'c 'b)
                            (make-generic 'chain 1 (classifiers k3)))))
         (add-handlers! chain (list (cons '(a) (lambda (x) 'a)) (cons '(c) (lambda (x) 'c))))
         (and (eq? (chain 'c) 'c) (eq? (chain 'b) 'a) (eq? (chain 'a) 'a)))))

;; ---- conflicts are found before the first call, as a whole ----
;; (a _) and (_ b) both match (a b) and neither dominates: refused on
;; check.  Committed together with (a b), the set is fine.
(define g1 (make-generic 'g1 2 (classifiers skill-kind job)))
(define (irritants-of thunk)            ; flattened one level: a list irritant contributes its members
  (guard (e (#t (if (error? e)
                    (let loop ((l (condition-irritants e)) (acc '()))
                      (cond ((null? l) (reverse acc))
                            ((and (pair? (car l)) (pair? (caar l))) (loop (cdr l) (append (reverse (car l)) acc)))
                            (else (loop (cdr l) (cons (car l) acc)))))
                    '())))
    (thunk) '()))
(define check-ok
  (and ;; the ambiguous pair is refused at COMMIT, naming the tuple it cannot decide
       (refused? 'add-handlers! (lambda () (add-handlers! g1 (list (cons '(fire _) (lambda (s t) 1))
                                                                   (cons '(_ mage) (lambda (s t) 2))))))
       (member '(fire mage) (irritants-of (lambda () (add-handlers! g1 (list (cons '(fire _) (lambda (s t) 1))
                                                                             (cons '(_ mage) (lambda (s t) 2)))))))
       (null? (generic-handlers g1))                                  ; nothing of the refused batch landed
       (begin (generic-check! g1) #t)                                 ; an empty generic checks fine
       ;; the dominator repairs it -- committed as one transaction, in any of the six orders
       (let loop ((orders '((0 1 2) (0 2 1) (1 0 2) (1 2 0) (2 0 1) (2 1 0))))
         (or (null? orders)
             (let* ((all (vector (cons '(fire _) (lambda (s t) 1))
                                 (cons '(_ mage) (lambda (s t) 2))
                                 (cons '(fire mage) (lambda (s t) 3))))
                    (g2 (make-generic 'g2 2 (classifiers skill-kind job))))
               (add-handlers! g2 (map (lambda (i) (vector-ref all i)) (car orders)))
               (and (= (g2 '(fire . 1) '(al . mage)) 3)
                    (= (g2 '(fire . 1) '(bo . warrior)) 1)
                    (= (g2 '(ice . 1) '(al . mage)) 2)
                    (= 3 (length (generic-handlers g2)))
                    (loop (cdr orders))))))))

;; ---- every change is a transaction ----
(define g3 (make-generic 'g3 2 (classifiers skill-kind job)))
(add-handler! g3 '(fire _) (lambda (s t) 'fire))
(define transaction-ok
  (and (= 1 (length (generic-handlers g3)))
       ;; a second commit that creates an unrepaired overlap is refused, and
       ;; the old configuration still dispatches
       (refused? 'add-handler! (lambda () (add-handler! g3 '(_ mage) (lambda (s t) 'mage))))
       (= 1 (length (generic-handlers g3)))
       (eq? (g3 '(fire . 1) '(al . mage)) 'fire)
       ;; the same two, committed together, are accepted
       (begin (add-handlers! g3 (list (cons '(_ mage) (lambda (s t) 'mage))
                                      (cons '(fire mage) (lambda (s t) 'both))))
              (= 3 (length (generic-handlers g3))))
       (eq? (g3 '(fire . 1) '(al . mage)) 'both)
       ;; removing the dominator would expose the overlap: refused, nothing removed
       (refused? 'remove-handler! (lambda () (remove-handler! g3 '(fire mage))))
       (= 3 (length (generic-handlers g3)))
       (eq? (g3 '(fire . 1) '(al . mage)) 'both)
       ;; a failed batch leaves nothing behind: one bad member spoils the whole transaction
       (refused? 'add-handlers! (lambda () (add-handlers! g3 (list (cons '(ice _) (lambda (s t) 'ice))
                                                                   (cons '(_ healer) (lambda (s t) 'heal))))))
       (= 3 (length (generic-handlers g3)))
       ;; a legal removal goes through, and the table forgets the removed handler
       (begin (remove-handler! g3 '(_ mage)) #t)
       (= 2 (length (generic-handlers g3)))
       (refused? 'g3 (lambda () (g3 '(ice . 1) '(al . mage))))   ; nothing applies to ice-on-mage any more
       ;; handlers are listed in registration order
       (equal? (map car (generic-handlers g3)) '((fire _) (fire mage)))
       ;; a relation change that creates an overlap is refused and does not take effect
       (let* ((k (define-classifier 'k (lambda (x) x) '(a b c)))
              (h (make-generic 'h 1 (classifiers k))))
         (add-handlers! h (list (cons '(a) (lambda (x) 'a)) (cons '(b) (lambda (x) 'b))))
         (declare-subtag! k 'c 'a)                              ; fine: c dispatches as a's descendant
         (and (eq? (h 'c) 'a)
              (refused? 'declare-subtag! (lambda () (declare-subtag! k 'c 'b)))   ; would make c ambiguous
              (not (subtag? k 'c 'b))                             ; the relation did not take effect
              (eq? (h 'c) 'a)))))

;; ---- the diamond: a common descendant makes (warrior) and (healer) overlap ----
(define g4 (make-generic 'g4 1 (classifiers job)))
(define diamond-ok
  (and ;; (warrior) and (healer) both match a paladin and neither dominates: refused at commit
       (refused? 'add-handlers! (lambda () (add-handlers! g4 (list (cons '(warrior) (lambda (t) 'w))
                                                                   (cons '(healer) (lambda (t) 'h))))))
       (null? (generic-handlers g4))
       ;; with the common descendant's own handler in the same transaction, the set is decidable
       (begin (add-handlers! g4 (list (cons '(warrior) (lambda (t) 'w))
                                      (cons '(healer) (lambda (t) 'h))
                                      (cons '(paladin) (lambda (t) 'p))))
              #t)
       (eq? (g4 '(x . paladin)) 'p)
       (eq? (g4 '(x . warrior)) 'w)
       (eq? (g4 '(x . healer)) 'h)))

;; ---- default, no default, out-of-domain, arity limits ----
(define g5 (make-generic 'g5 1 (classifiers skill-kind) (lambda (s) 'dflt)))
(add-handler! g5 '(fire) (lambda (s) 'f))
(define g6 (make-generic 'g6 1 (classifiers skill-kind)))
(add-handler! g6 '(fire) (lambda (s) 'f))
(define edges-ok
  (and (eq? (g5 '(ice . 1)) 'dflt)
       (refused? 'g6 (lambda () (g6 '(ice . 1))))            ; nothing applies, no default: named after the generic
       (member '(ice . 1) (irritants-of (lambda () (g6 '(ice . 1)))))   ; ...and it says which arguments
       (refused? 'g5 (lambda () (g5 '(plasma . 1))))         ; a tag outside the domain is an error even with a default
       (refused? 'add-handler! (lambda () (add-handler! g6 '(plasma) (lambda (s) 0))))   ; ...also in a signature
       (refused? 'add-handler! (lambda () (add-handler! g6 '(fire) (lambda (s) 0))))     ; duplicate signature
       (refused? 'add-handler! (lambda () (add-handler! g6 '(fire fire) (lambda (s) 0)))) ; wrong length
       (refused? 'make-generic (lambda () (make-generic 'g7 5 (classifiers skill-kind skill-kind skill-kind skill-kind skill-kind))))
       ;; three and four arguments work, and every argument reaches the handler in place
       (let ((g8 (make-generic 'g8 3 (classifiers skill-kind job job)))
             (g9 (make-generic 'g9 4 (classifiers skill-kind job job skill-kind))))
         (add-handler! g8 '(_ _ mage) (lambda (a b c) (list c b a)))
         (add-handler! g9 '(fire _ _ _) (lambda (a b c d) (list d c b a)))
         (and (equal? (g8 '(fire . 1) '(x . warrior) '(y . mage)) '((y . mage) (x . warrior) (fire . 1)))
              (equal? (g9 '(fire . 1) '(x . warrior) '(y . mage) '(ice . 2)) '((ice . 2) (y . mage) (x . warrior) (fire . 1)))))
       ;; a default may be installed after construction
       (let ((g10 (make-generic 'g10 1 (classifiers skill-kind))))
         (generic-default! g10 (lambda (s) 'later))
         (and (eq? (g10 '(ice . 1)) 'later)
              (eq? (generic-name g10) 'g10) (= (generic-arity g10) 1) (generic? g10)))))

;; predicate mode lives in test/lng-generic-pred.ss, parked until the wasm target
;; gives a top-level procedure one identity (see test/procedure-identity.ss).

;; ---- the configuration is the library's, not the caller's ----
;; A signature list handed to add-handler! or handed back by
;; generic-handlers is a copy: mutating it must not move a handler.
(define g11 (make-generic 'g11 1 (classifiers skill-kind)))
(define sig (list 'fire))
(add-handler! g11 sig (lambda (s) 'f))
(set-car! sig 'ice)
(define (dispatches-to? g arg want)          ; #f rather than a trap when the handler went missing
  (guard (e (#t #f)) (eq? (g arg) want)))
(define spec (classifiers skill-kind))              ; the spec is a list the caller still holds
(define g11b (make-generic 'g11b 1 spec))
(define owned-ok
  (and (dispatches-to? g11 '(fire . 1) 'f)
       (refused? 'g11 (lambda () (g11 '(ice . 1))))
       (begin (set-car! (car (car (generic-handlers g11))) 'ice) #t)   ; the enumeration is a copy too
       (dispatches-to? g11 '(fire . 1) 'f)
       ;; the classifier spec is copied too: mutating the caller's list changes nothing
       (begin (add-handler! g11b '(fire) (lambda (s) 'f)) (set-car! (cdr spec) job) #t)   ; overwrite INSIDE the retained tail, not the outer link
       (dispatches-to? g11b '(fire . 1) 'f)
       ;; a mode must be named: nothing is implicitly predicate mode
       (refused? 'make-generic (lambda () (make-generic 'g12 1)))))

;; ---- overlap regions resolved in part: every tuple judged, not every pair ----
;; (fire _) and (_ mage) overlap at (fire mage); a third signature that
;; resolves it must be THE dominator there, and two competing resolvers
;; are ambiguous again.
(define partial-ok
  (let ((g (make-generic 'g13 2 (classifiers skill-kind job)))
        (h (make-generic 'g14 2 (classifiers skill-kind job))))
    (and (begin (add-handlers! g (list (cons '(fire _) (lambda (s t) 1))
                                       (cons '(_ mage) (lambda (s t) 2))
                                       (cons '(fire mage) (lambda (s t) 3))))
                #t)
         ;; a second resolver at the same tuple: refused, with every candidate named
         (refused? 'add-handler! (lambda () (add-handler! g '(fire mage) (lambda (s t) 4))))   ; duplicate first
         (let ((irr (irritants-of (lambda () (add-handlers! h (list (cons '(fire _) (lambda (s t) 1))
                                                                    (cons '(_ mage) (lambda (s t) 2))))))))
           (and (member '(fire _) irr) (member '(_ mage) irr) (member '(fire mage) irr)))
         ;; four candidates at one tuple, two of them "resolvers" that beat one side each
         ;; but not the other: still ambiguous, and all four are named
         (let* ((k (define-classifier 'k7 (lambda (x) x) '(top l r ll rr bottom)))
                (q (make-generic 'g19 1 (classifiers k))))
           (declare-subtag! k 'l 'top) (declare-subtag! k 'r 'top)
           (declare-subtag! k 'll 'l) (declare-subtag! k 'rr 'r)
           (declare-subtag! k 'bottom 'll) (declare-subtag! k 'bottom 'rr)
           (let ((irr (irritants-of (lambda () (add-handlers! q (list (cons '(l) (lambda (x) 'l)) (cons '(r) (lambda (x) 'r))
                                                                      (cons '(ll) (lambda (x) 'll)) (cons '(rr) (lambda (x) 'rr))))))))
             (and (member '(l) irr) (member '(r) irr) (member '(ll) irr) (member '(rr) irr)
                  (member '(bottom) irr)
                  (null? (generic-handlers q))
                  ;; only the tuple's own signature settles it
                  (begin (add-handlers! q (list (cons '(l) (lambda (x) 'l)) (cons '(r) (lambda (x) 'r))
                                                (cons '(ll) (lambda (x) 'll)) (cons '(rr) (lambda (x) 'rr))
                                                (cons '(bottom) (lambda (x) 'b))))
                         #t)
                  (eq? (q 'bottom) 'b) (eq? (q 'll) 'll) (eq? (q 'rr) 'rr)))))))

;; ---- a relation change is one transaction across every generic that depends on it ----
(define shared-ok
  (let* ((k (define-classifier 'k5 (lambda (x) x) '(a b c)))
         (breaks (make-generic 'breaks 1 (classifiers k)))   ; made FIRST: whatever the watcher order, it must not be the only one consulted
         (fine (make-generic 'fine 1 (classifiers k))))      ; would be fine with c < b, and is validated in the same transaction
    (add-handlers! breaks (list (cons '(a) (lambda (x) 'a)) (cons '(b) (lambda (x) 'b))))
    (add-handlers! fine (list (cons '(b) (lambda (x) 'b))))
    (declare-subtag! k 'c 'a)
    (and (refused? 'fine (lambda () (fine 'c)))                  ; c is not under b: nothing applies, and this fills fine's table for c
         (eq? (fine 'b) 'b)                                     ; ...and for b
         (refused? 'declare-subtag! (lambda () (declare-subtag! k 'c 'b)))
         (not (subtag? k 'c 'b))
         ;; the rejected relation reached no table: through DISPATCH (the cached path), not the trace
         (eq? (breaks 'c) 'a)
         (refused? 'fine (lambda () (fine 'c)))
         ;; and the reverse order of the two generics gives the same answers
         (let* ((k2 (define-classifier 'k5b (lambda (x) x) '(a b c)))
                (fine2 (make-generic 'fine2 1 (classifiers k2)))
                (breaks2 (make-generic 'breaks2 1 (classifiers k2))))
           (add-handlers! fine2 (list (cons '(b) (lambda (x) 'b))))
           (add-handlers! breaks2 (list (cons '(a) (lambda (x) 'a)) (cons '(b) (lambda (x) 'b))))
           (declare-subtag! k2 'c 'a)
           (and (refused? 'fine2 (lambda () (fine2 'c)))
                (refused? 'declare-subtag! (lambda () (declare-subtag! k2 'c 'b)))
                (refused? 'fine2 (lambda () (fine2 'c)))
                (eq? (breaks2 'c) 'a))))))

;; ---- a failed commit leaves the dispatch table as it was ----
(define cache-ok
  (let ((g (make-generic 'g15 1 (classifiers job))))
    (add-handler! g '(warrior) (lambda (t) 'w))
    (and (eq? (g '(x . warrior)) 'w)                               ; fills the table for warrior
         (eq? (g '(x . paladin)) 'w)                               ; ...and for paladin, through warrior
         ;; a batch that is well-formed but ambiguous: (healer) overlaps (warrior) at paladin
         (refused? 'add-handlers! (lambda () (add-handlers! g (list (cons '(mage) (lambda (t) 'm))
                                                                    (cons '(healer) (lambda (t) 'h))))))
         (refused? 'g15 (lambda () (g '(x . mage))))               ; mage did not land (errors carry the generic's NAME)
         (eq? (g '(x . paladin)) 'w)                               ; the cached answer is the old one, through dispatch
         (eq? (g '(x . warrior)) 'w))))

;; ---- a deep diamond: the common descendant two levels down ----
(define deep-ok
  (let* ((k (define-classifier 'k6 (lambda (x) x) '(top l r ll rr bottom)))
         (g (make-generic 'g16 1 (classifiers k))))
    (declare-subtag! k 'l 'top) (declare-subtag! k 'r 'top)
    (declare-subtag! k 'll 'l) (declare-subtag! k 'rr 'r)
    (declare-subtag! k 'bottom 'll) (declare-subtag! k 'bottom 'rr)
    (and (refused? 'add-handlers! (lambda () (add-handlers! g (list (cons '(l) (lambda (x) 'l)) (cons '(r) (lambda (x) 'r))))))
         (begin (add-handlers! g (list (cons '(l) (lambda (x) 'l)) (cons '(r) (lambda (x) 'r)) (cons '(bottom) (lambda (x) 'b)))) #t)
         (eq? (g 'bottom) 'b) (eq? (g 'll) 'l) (eq? (g 'rr) 'r)
         (refused? 'g16 (lambda () (g 'top))))))

;; ---- a default receives every argument, in place ----
(define default-args-ok
  (let ((g (make-generic 'g17 3 (classifiers skill-kind job job) (lambda (a b c) (list c b a)))))
    (and (equal? (g '(ice . 1) '(x . mage) '(y . healer)) '((y . healer) (x . mage) (ice . 1)))
         ;; and the no-handler error names all of them
         (let* ((h (make-generic 'g18 3 (classifiers skill-kind job job)))
                (irr (irritants-of (lambda () (h '(ice . 1) '(x . mage) '(y . healer))))))
           (and (member '(ice . 1) irr) (member '(x . mage) irr) (member '(y . healer) irr) #t)))))

;; ---- a watcher that fails while committing does not undo the commit ----
;; Validation passed, so the relation is the configuration now; a
;; watcher raising in its commit phase is that watcher's failure.  The
;; relation stays installed, every OTHER dependent still gets its
;; commit (tables cleared), and the error surfaces afterwards.
(define commit-raise-ok
  (let* ((k (define-classifier 'k8 (lambda (x) x) '(a b c)))
         (gg (make-generic 'gg 1 (classifiers k))))
    (add-handler! gg '(a) (lambda (x) 'a))
    (and (refused? 'gg (lambda () (gg 'c)))                       ; c is not under a yet; fills the table with "nothing"
         (begin (classifier-watch! k (lambda (phase who) (when (eq? phase 'commit) (error 'boom "watcher failed")))) #t)
         (guard (e (#t (eq? (condition-who e) 'boom)))            ; the failure surfaces
           (declare-subtag! k 'c 'a) #f)
         (subtag? k 'c 'a)                                          ; ...but the relation is installed
         (dispatches-to? gg 'c 'a)                                  ; ...and gg's table was cleared and refilled under it
         ;; a watcher that raises the value #f is still a raising watcher: it surfaces, not swallowed
         (let* ((k2 (define-classifier 'k9 (lambda (x) x) '(a b c))))
           (classifier-watch! k2 (lambda (phase who) (when (eq? phase 'commit) (raise #f))))
           (and (guard (e (#t (eq? e #f))) (declare-subtag! k2 'c 'a) #f)   ; normal completion is the FAILURE here: #f, not a truthy tag
                (subtag? k2 'c 'a))))))

(let ((all (list (report "commit-raise" commit-raise-ok) (report "owned" owned-ok) (report "partial" partial-ok) (report "shared" shared-ok)
                 (report "cache" cache-ok) (report "deep" deep-ok) (report "default-args" default-args-ok)
                 (report "pred" pred-ok) (report "dispatch" dispatch-ok) (report "check" check-ok)
                 (report "transaction" transaction-ok) (report "diamond" diamond-ok)
                 (report "edges" edges-ok))))
  (let loop ((l all)) (or (null? l) (and (car l) (loop (cdr l))))))
