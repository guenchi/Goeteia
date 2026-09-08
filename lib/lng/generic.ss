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

;; Multi-argument dispatch whose conflicts are found by the program,
;; not settled by the order the handlers happened to be registered in.
;;
;; A generic is a fixed-arity procedure with a table of handlers.  A
;; handler's SIGNATURE says which arguments it applies to, one entry
;; per position, and the most specific applicable handler wins.  There
;; are no classes, no inheritance, no method combination and no
;; call-next-method: a handler either wins or it does not run.
;;
;; TAG MODE (recommended).  Each position has a classifier from
;; (lng pred), so an argument's tag comes from a declared finite set.
;; A signature entry is a tag or `_'.  Finiteness is the whole point:
;; every tuple two signatures could both match can be ENUMERATED, so
;; "these two handlers are ambiguous" is a fact about the program that
;; is reported when the handlers are committed, not when a player
;; finally casts that spell.
;;
;; PREDICATE MODE.  Signatures are lists of ordinary predicates.
;; Nothing about open-ended procedures is enumerable, so ambiguity can
;; only be reported at the call.  It is the documented escape hatch --
;; and it is SUSPENDED on the wasm target, where a top-level
;; (define (f x) ...) yields a fresh closure at every reference, so two
;; mentions of one predicate are not eq? and no relation declared about
;; it can be found again.  It works on the JS target and under Chez;
;; tag mode is unaffected, because tags are symbols.  See docs/lng.md.
;;
;; EVERY CHANGE IS A TRANSACTION.  add-handler!, add-handlers!,
;; remove-handler! and a lattice change in (lng pred) each validate the
;; WHOLE proposed configuration before committing it, and leave the
;; previous one untouched when they refuse.  That is what makes the
;; rule independent of order: two signatures that overlap and a third
;; that resolves them are legal committed together and refused
;; committed apart, and the refusal says which tuple it could not
;; decide.  The dispatch table is emptied on every commit.
;;
(library (lng generic)
  (export make-generic generic? generic-name generic-arity
          classifiers
          add-handler! add-handlers! remove-handler!
          generic-default! generic-check! generic-handlers
          dispatch-trace)
  (import (rnrs) (lng pred))

  (define-record-type (gen $make-gen $gen?)
    (fields (immutable name gen-name)
            (immutable arity gen-arity)
            (immutable mode $mode)              ; 'tags | 'predicates
            (immutable cs $cs)                  ; classifiers, or '()
            (mutable handlers $handlers $handlers!)   ; ((sig . proc) ...)
            (mutable default $default $default!)
            (mutable table $table $table!)))

  ;; the callable is what a caller holds, so the record is found from it
  (define $gens (make-eq-hashtable))
  (define ($of who x)
    (let ((g (and (procedure? x) (hashtable-ref $gens x #f))))
      (unless g (error who "not a generic" x))
      g))
  (define (generic? x)
    (and (procedure? x) (hashtable-ref $gens x #f) #t))
  (define (generic-name x) (gen-name ($of 'generic-name x)))
  (define (generic-arity x) (gen-arity ($of 'generic-arity x)))

  ;; the classifier list a tag-mode generic dispatches through
  (define (classifiers . cs)
    (let loop ((l cs))
      (unless (null? l)
        (unless (classifier? (car l))
          (error 'classifiers "not a classifier" (car l)))
        (loop (cdr l))))
    (cons '$classifiers cs))

  (define ($fresh-table) (make-hashtable equal-hash equal?))

  (define ($copy l)
    (let loop ((l l) (acc '()))
      (if (null? l) (reverse acc) (loop (cdr l) (cons (car l) acc)))))

  ;; A computed list of irritants goes through `error' as ONE irritant
  ;; that happens to be a list -- there is no `apply' here to spread it,
  ;; and reaching for the prelude's own condition constructor would tie
  ;; this library to a private name and to one host.

  (define (make-generic name arity . rest)
    (unless (symbol? name)
      (error 'make-generic "a generic's name is a symbol" name))
    (unless (and (integer? arity) (<= 1 arity) (<= arity 4))
      (error 'make-generic
             "arity must be 1, 2, 3 or 4 -- dispatch is written out per arity"
             arity))
    (when (null? rest)
      (error 'make-generic
             "say the mode: (classifiers c ...) or 'predicates"
             name))
    (let* ((spec (car rest))
           (dflt (if (null? (cdr rest)) #f (cadr rest)))
           (tags? (and (pair? spec) (eq? (car spec) '$classifiers)))
           ;; the third place a caller's list reached in: the spec's
           ;; tail decides which classifiers this generic dispatches
           ;; through, so holding it by reference would put the whole
           ;; configuration back in the caller's hands
           (cs (if tags? ($copy (cdr spec)) '())))
      (unless (or tags? (eq? spec 'predicates))
        (error 'make-generic
               "the third operand is (classifiers c ...) or 'predicates"
               spec))
      (when (and tags? (not (= (length cs) arity)))
        (error 'make-generic "one classifier per argument" arity
               (length cs)))
      (when (and dflt (not (procedure? dflt)))
        (error 'make-generic "a default is a procedure" dflt))
      (let* ((g ($make-gen name arity (if tags? 'tags 'predicates)
                           cs '() dflt ($fresh-table)))
             (f (cond ((= arity 1) (lambda (a) ($invoke g (list a))))
                      ((= arity 2) (lambda (a b) ($invoke g (list a b))))
                      ((= arity 3)
                       (lambda (a b c) ($invoke g (list a b c))))
                      (else
                       (lambda (a b c d) ($invoke g (list a b c d)))))))
        ;; a lattice change has to be able to refuse: register now, so
        ;; a generic built before the relation still gets checked
        (let watch ((l cs))
          (unless (null? l)
            (classifier-watch!
             (car l)
             (lambda (phase who)
               (if (eq? phase 'validate)
                   ($check who g ($handlers g))
                   ($table! g ($fresh-table)))))
            (watch (cdr l))))
        (hashtable-set! $gens f g)
        f)))

  ;; ---- signature shape, checked when a handler is offered ----
  (define ($check-sig who g sig)
    (unless (and (list? sig) (= (length sig) (gen-arity g)))
      (error who "a signature has one entry per argument"
             (gen-name g) (gen-arity g) sig))
    (if (eq? ($mode g) 'tags)
        (let loop ((s sig) (cs ($cs g)))
          (unless (null? s)
            (unless (eq? (car s) '_)
              (unless (and (symbol? (car s))
                           (memq (car s) (classifier-tags (car cs))))
                (error who "no such tag in this classifier's domain"
                       (gen-name g) (classifier-name (car cs)) (car s))))
            (loop (cdr s) (cdr cs))))
        (let loop ((s sig))
          (unless (null? s)
            (unless (procedure? (car s))
              (error who "a predicate signature holds procedures"
                     (gen-name g) (car s)))
            (loop (cdr s))))))

  ;; Two signatures are the same when they name the same thing at every
  ;; position: symbols by identity, predicates by OBJECT identity --
  ;; two lambdas with the same body are two predicates.
  (define ($same-sig? a b)
    (let loop ((a a) (b b))
      (cond ((null? a) (null? b))
            ((null? b) #f)
            ((eq? (car a) (car b)) (loop (cdr a) (cdr b)))
            (else #f))))

  (define ($find-sig sigs sig)
    (let loop ((l sigs))
      (cond ((null? l) #f)
            (($same-sig? (car (car l)) sig) (car l))
            (else (loop (cdr l))))))

  ;; ---- specificity ----
  ;; `_' is the top of every position: everything is at least as
  ;; specific as it, and it is more specific than nothing.
  (define ($elem<= c a b)
    (cond ((eq? b '_) #t)
          ((eq? a '_) #f)
          (else (subtag? c a b))))

  (define ($sig<= cs a b)
    (let loop ((cs cs) (a a) (b b))
      (cond ((null? cs) #t)
            (($elem<= (car cs) (car a) (car b)) (loop (cdr cs) (cdr a) (cdr b)))
            (else #f))))

  (define ($pred-sig<= a b)
    (let loop ((a a) (b b))
      (cond ((null? a) #t)
            ((or (eq? (car a) (car b)) (subset? (car a) (car b)))
             (loop (cdr a) (cdr b)))
            (else #f))))

  ;; the one entry that is at least as specific as every candidate,
  ;; or #f when there is none or more than one
  (define ($dominator le? cands)
    (let loop ((l cands) (found #f) (n 0))
      (cond ((null? l) (and (= n 1) found))
            ((let every ((r cands))
               (cond ((null? r) #t)
                     ((le? (car (car l)) (car (car r))) (every (cdr r)))
                     (else #f)))
             (loop (cdr l) (car l) (+ n 1)))
            (else (loop (cdr l) found n)))))

  ;; ---- tag mode: enumerate what two signatures could both match ----
  (define ($elem-set c e)
    (if (eq? e '_) (classifier-tags c) (descendants c e)))

  (define ($meet a b)
    (let loop ((l a) (acc '()))
      (cond ((null? l) (reverse acc))
            ((memq (car l) b) (loop (cdr l) (cons (car l) acc)))
            (else (loop (cdr l) acc)))))

  (define ($matches? cs sig tuple)
    (let loop ((cs cs) (s sig) (t tuple))
      (cond ((null? cs) #t)
            ((or (eq? (car s) '_) (subtag? (car cs) (car t) (car s)))
             (loop (cdr cs) (cdr s) (cdr t)))
            (else #f))))

  (define ($matching cs handlers tuple)
    (let loop ((l handlers) (acc '()))
      (cond ((null? l) (reverse acc))
            (($matches? cs (car (car l)) tuple)
             (loop (cdr l) (cons (car l) acc)))
            (else (loop (cdr l) acc)))))

  ;; walk the cartesian product without building it
  (define ($for-tuples sets proc)
    (let walk ((sets sets) (acc '()))
      (if (null? sets)
          (proc (reverse acc))
          (let loop ((l (car sets)))
            (unless (null? l)
              (walk (cdr sets) (cons (car l) acc))
              (loop (cdr l)))))))

  ;; The whole rule: for every pair of signatures, every tuple they can
  ;; BOTH match must have exactly one dominator among all the
  ;; signatures that match it.  Overlap alone is not an error -- (a _)
  ;; and (_ b) are fine once (a b) is there to decide their overlap.
  (define ($check-tag-set who g handlers)
    (let ((cs ($cs g)))
      (let outer ((l handlers))
        (unless (null? l)
          (let inner ((r (cdr l)))
            (unless (null? r)
              (let ((sets (let build ((cs cs)
                                      (a (car (car l))) (b (car (car r)))
                                      (acc '()))
                            (if (null? cs)
                                (reverse acc)
                                (build (cdr cs) (cdr a) (cdr b)
                                       (cons ($meet ($elem-set (car cs) (car a))
                                                    ($elem-set (car cs) (car b)))
                                             acc))))))
                (unless (let empty? ((s sets))
                          (cond ((null? s) #f)
                                ((null? (car s)) #t)
                                (else (empty? (cdr s)))))
                  ($for-tuples
                   sets
                   (lambda (tuple)
                     (let ((cands ($matching cs handlers tuple)))
                       (unless ($dominator (lambda (x y) ($sig<= cs x y))
                                           cands)
                         ;; every candidate AT THIS TUPLE, not just the
                         ;; pair the enumeration happened to be on: the
                         ;; two that overlap are rarely the whole story
                         ;; once a third signature is involved
                         (error who
                                "handlers match the same arguments and none is more specific"
                                (gen-name g) tuple
                                (map (lambda (h) ($copy (car h))) cands))))))))
              (inner (cdr r))))
          (outer (cdr l))))))

  (define ($check who g handlers)
    (when (eq? ($mode g) 'tags)
      ($check-tag-set who g handlers)))

  ;; The proposal is judged BEFORE it is installed, and installed in one
  ;; step.  Judging an installed configuration and rolling it back would
  ;; work here, but nothing else that a refusal has to undo can be
  ;; rolled back as easily -- a dispatch table filled in between is
  ;; already wrong -- so the rule is the same everywhere: decide first,
  ;; then swap.
  (define ($commit! who g handlers)
    ($check who g handlers)
    ($handlers! g handlers)
    ($table! g ($fresh-table)))

  (define (generic-check! x)
    (let ((g ($of 'generic-check! x)))
      ($check 'generic-check! g ($handlers g))
      #t))

  ;; every signature handed out is a copy: the configuration belongs to
  ;; the library, and a caller editing what it was given must not be
  ;; able to move a handler behind the checks
  (define (generic-handlers x)
    (let loop ((l ($handlers ($of 'generic-handlers x))) (acc '()))
      (if (null? l) (reverse acc)
          (loop (cdr l)
                (cons (cons ($copy (car (car l))) (cdr (car l))) acc)))))

  (define (generic-default! x proc)
    (unless (procedure? proc)
      (error 'generic-default! "a default is a procedure" proc))
    (let ((g ($of 'generic-default! x)))
      ($default! g proc)
      ;; the table can hold "nothing applies here", which is an answer
      ;; about the default as much as about the handlers
      ($table! g ($fresh-table)))
    #t)

  (define (add-handler! x sig proc) ($add 'add-handler! x (list (cons sig proc))))
  (define (add-handlers! x pairs)
    (unless (list? pairs)
      (error 'add-handlers! "a batch is a list of (signature . procedure)" pairs))
    ($add 'add-handlers! x pairs))

  (define ($add who x pairs)
    (let ((g ($of who x)))
      ;; shape first, so a malformed member is named before any of the
      ;; batch is considered
      (let check ((l pairs) (seen '()))
        (unless (null? l)
          (unless (pair? (car l))
            (error who "a handler is (signature . procedure)" (car l)))
          (let ((sig (car (car l))) (proc (cdr (car l))))
            ($check-sig who g sig)
            (unless (procedure? proc)
              (error who "a handler is (signature . procedure)" (car l)))
            (when ($find-sig ($handlers g) sig)
              (error who "that signature already has a handler"
                     (gen-name g) sig))
            (when ($find-sig seen sig)
              (error who "that signature appears twice in one batch"
                     (gen-name g) sig))
            (check (cdr l) (cons (cons sig proc) seen)))))
      ;; from here the signatures are the library's own copies
      ($commit! who g
                (let append-all ((l pairs) (acc (reverse ($handlers g))))
                  (if (null? l)
                      (reverse acc)
                      (append-all (cdr l)
                                  (cons (cons ($copy (car (car l)))
                                              (cdr (car l)))
                                        acc)))))
      #t))

  (define (remove-handler! x sig)
    (let* ((g ($of 'remove-handler! x))
           (hit ($find-sig ($handlers g) sig)))
      (unless hit
        (error 'remove-handler! "no handler has that signature"
               (gen-name g) sig))
      ($commit! 'remove-handler! g
                (let loop ((l ($handlers g)) (acc '()))
                  (cond ((null? l) (reverse acc))
                        ((eq? (car l) hit) (loop (cdr l) acc))
                        (else (loop (cdr l) (cons (car l) acc))))))
      #t))

  ;; ---- dispatch ----
  (define ($tuple g args who)
    (let loop ((cs ($cs g)) (a args) (acc '()))
      (if (null? cs)
          (reverse acc)
          (loop (cdr cs) (cdr a)
                (cons (classify-as who (car cs) (car a)) acc)))))

  (define ($applicable g args)
    (let loop ((l ($handlers g)) (acc '()))
      (cond ((null? l) (reverse acc))
            ((let every ((s (car (car l))) (a args))
               (cond ((null? s) #t)
                     (((car s) (car a)) (every (cdr s) (cdr a)))
                     (else #f)))
             (loop (cdr l) (cons (car l) acc)))
            (else (loop (cdr l) acc)))))

  ;; 'none = nothing applies (the default's business); 'ambiguous =
  ;; several apply and none is more specific, which is NOT the default's
  ;; business -- handing it over would answer a question the program
  ;; never resolved
  (define ($winner g tuple)
    (let* ((cs ($cs g))
           (cands ($matching cs ($handlers g) tuple)))
      (if (null? cands)
          'none
          (let ((d ($dominator (lambda (x y) ($sig<= cs x y)) cands)))
            (if d (cdr d) 'ambiguous)))))

  (define ($ambiguous g tuple)
    (let* ((cs ($cs g))
           (cands ($matching cs ($handlers g) tuple)))
      (error (gen-name g)
             "handlers match the same arguments and none is more specific"
             tuple (map (lambda (h) ($copy (car h))) cands))))

  (define ($call proc args arity)
    (cond ((= arity 1) (proc (car args)))
          ((= arity 2) (proc (car args) (cadr args)))
          ((= arity 3) (proc (car args) (cadr args) (caddr args)))
          (else (proc (car args) (cadr args) (caddr args) (cadddr args)))))

  (define ($no-handler g args)
    (let ((d ($default g)))
      (if d
          ($call d args (gen-arity g))
          ;; every argument, not the first two: the one that made this
          ;; call unanswerable is as likely to be the fourth
          (error (gen-name g) "no handler applies to these arguments"
                 ($copy args)))))

  (define ($invoke g args)
    (if (eq? ($mode g) 'tags)
        (let* ((who (gen-name g))
               ;; an out-of-domain tag is an error even when there is a
               ;; default: the domain is what every conflict check was
               ;; computed over, so a value outside it was never
               ;; reasoned about
               (tuple ($tuple g args who))
               (hit (hashtable-ref ($table g) tuple #f))
               (w (or hit
                      (let ((w ($winner g tuple)))
                        (hashtable-set! ($table g) tuple w)
                        w))))
          (cond ((eq? w 'none) ($no-handler g args))
                ((eq? w 'ambiguous) ($ambiguous g tuple))
                (else ($call w args (gen-arity g)))))
        (let ((cands ($applicable g args)))
          (cond ((null? cands) ($no-handler g args))
                ((null? (cdr cands)) ($call (cdr (car cands)) args (gen-arity g)))
                (else
                 (let ((d ($dominator $pred-sig<= cands)))
                   (if d
                       ($call (cdr d) args (gen-arity g))
                       (error (gen-name g)
                              "handlers match the same arguments and none is more specific"
                              ($copy args)))))))))

  ;; What a call WOULD do, without doing it: the tags (or #f in
  ;; predicate mode), every candidate in registration order, and the
  ;; winner's signature.  It calls no HANDLER -- the classifiers do
  ;; run, because the tags are what it reports.
  (define (dispatch-trace x args)
    (let ((g ($of 'dispatch-trace x)))
      (unless (and (list? args) (= (length args) (gen-arity g)))
        (error 'dispatch-trace "one argument per position"
               (gen-name g) (gen-arity g) args))
      (if (eq? ($mode g) 'tags)
          (let* ((tuple ($tuple g args 'dispatch-trace))
                 (cands ($matching ($cs g) ($handlers g) tuple))
                 (d ($dominator (lambda (a b) ($sig<= ($cs g) a b)) cands)))
            (list tuple (map (lambda (h) ($copy (car h))) cands)
                  (and d ($copy (car d)))))
          (let* ((cands ($applicable g args))
                 (d (if (null? cands)
                        #f
                        (if (null? (cdr cands))
                            (car cands)
                            ($dominator $pred-sig<= cands)))))
            (list #f (map (lambda (h) ($copy (car h))) cands)
                  (and d ($copy (car d))))))))
  )
