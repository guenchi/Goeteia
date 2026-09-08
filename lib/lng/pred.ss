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

;; Named classifications and the relations between them.
;;
;; Dispatch on more than one argument needs an answer to "which of
;; these two handlers is more specific".  A predicate cannot answer it
;; -- two opaque procedures have no computable relation -- so the
;; relation is DECLARED, and this library is where it lives.  It holds
;; nothing else: no dispatch, no methods, no classes.  (gfx gltf) and
;; the rest of the tree do not know it exists; (lng generic) and any
;; later printer hook import it, which is the only reason it is a
;; library of its own rather than a section of that one.
;;
;; Two vocabularies, because two kinds of program need different
;; things:
;;
;;   TAGS.  A classifier is a procedure from a value to a symbol out
;;   of a DECLARED FINITE set.  Because the set is finite, every tuple
;;   two handler signatures could both match can be enumerated, so a
;;   conflict is a fact about the program that can be found before it
;;   runs.  This is the recommended form.
;;
;;   PREDICATES.  Ordinary procedures, open-ended, unenumerable.  The
;;   relation is still declared, but nothing can be checked ahead of
;;   time; ambiguity is reported at the call.  The escape hatch -- and
;;   SUSPENDED on the wasm target, where a top-level (define (f x) ...)
;;   yields a fresh closure at every reference, so declare-subset! can
;;   never name the same object a signature holds.  Tags are symbols
;;   and are unaffected.  See docs/lng.md.
;;
;; Both relations are stored as a REFLEXIVE, TRANSITIVE closure and a
;; declaration that would close a cycle is refused: with a cycle, "more
;; specific" stops being an order and the winner would depend on the
;; order the handlers happened to be registered in.
;;
;; A tag's identity is its symbol, so two spellings of the same tag are
;; the same tag.  A predicate's identity is the PROCEDURE OBJECT: two
;; lambdas with identical bodies are two different predicates, and a
;; relation declared about one says nothing about the other.  Name your
;; predicates and pass the name.
;;
(library (lng pred)
  (export define-classifier classifier? classifier-name classifier-tags
          classify classify-as
          declare-subtag! subtag? descendants
          classifier-watch!
          declare-subset! subset?)
  (import (rnrs))

  (define-record-type (classifier $make-classifier classifier?)
    (fields (immutable name classifier-name)
            (immutable proc $classifier-proc)
            (immutable tags $tags)
            ;; the closure, as ((tag . ancestors-including-itself) ...)
            (mutable up $up $up!)
            ;; what to re-check when the relation changes; see
            ;; classifier-watch!
            (mutable watchers $watchers $watchers!)))

  ;; a value nothing outside this library can hand back, so it can
  ;; stand for "no condition" without colliding with a real one
  (define $none (list 'no-condition))

  (define ($copy l)
    (let loop ((l l) (acc '()))
      (if (null? l) (reverse acc) (loop (cdr l) (cons (car l) acc)))))

  ;; The domain a caller sees is a COPY.  The declared tag set is what
  ;; every conflict check was computed over, so handing out the list
  ;; itself would let a caller edit the ground the checks stand on.
  (define (classifier-tags c)
    (unless (classifier? c) (error 'classifier-tags "not a classifier" c))
    ($copy ($tags c)))

  (define ($union a b)                  ; a, plus what b adds
    (let loop ((l b) (acc a))
      (cond ((null? l) acc)
            ((memq (car l) acc) (loop (cdr l) acc))
            (else (loop (cdr l) (cons (car l) acc))))))

  (define ($check-tag who c t)
    (unless (classifier? c)
      (error who "not a classifier" c))
    (unless (and (symbol? t) (memq t ($tags c)))
      (error who "no such tag in this classifier's domain"
             (classifier-name c) t)))

  (define ($ancestors c t) (cdr (assq t ($up c))))

  ;; A classifier is a value, not a definition: it is returned, and the
  ;; caller binds it.  The tag domain is fixed here and never grows --
  ;; that finiteness is what makes conflicts decidable.
  (define (define-classifier name proc tags)
    (unless (symbol? name)
      (error 'define-classifier "a classifier's name is a symbol" name))
    (unless (procedure? proc)
      (error 'define-classifier
             "a classifier is a procedure from a value to a tag" proc))
    (unless (and (list? tags) (pair? tags))
      (error 'define-classifier
             "a classifier needs a non-empty finite tag domain" tags))
    (let loop ((l tags))
      (unless (null? l)
        (unless (symbol? (car l))
          (error 'define-classifier "a tag is a symbol" (car l)))
        (when (memq (car l) (cdr l))
          (error 'define-classifier "a tag is repeated in the domain"
                 (car l)))
        (loop (cdr l))))
    ;; the domain is copied in as well: a caller who keeps the list
    ;; it passed must not be able to change the domain afterwards
    (let ((own ($copy tags)))
      ($make-classifier name proc own
                        (map (lambda (t) (list t t)) own)
                        '())))

  ;; The tag of a value.  A classifier answering outside its declared
  ;; domain is an error and not a silent miss: the domain is what every
  ;; conflict check was computed over, so a value outside it has not
  ;; been reasoned about at all.  `classify-as' is the same check under
  ;; a caller's own name, so a dispatcher can refuse in its own voice
  ;; without a second copy of the rule.
  (define (classify c x) (classify-as 'classify c x))

  (define (classify-as who c x)
    (unless (classifier? c)
      (error who "not a classifier" c))
    (let ((t (($classifier-proc c) x)))
      (unless (and (symbol? t) (memq t ($tags c)))
        (error who "the classifier answered a tag outside its domain"
               (classifier-name c) t))
      t))

  ;; sub is a kind of super.  Refused when it would close a cycle, and
  ;; when either tag is outside the domain.
  ;;
  ;; A relation change is a TRANSACTION: every watcher runs against the
  ;; new closure, and if one refuses, the old closure is put back before
  ;; the refusal reaches the caller.  Otherwise a rejected declaration
  ;; would leave the lattice changed and the refusal would be a lie.
  (define (declare-subtag! c sub super)
    ($check-tag 'declare-subtag! c sub)
    ($check-tag 'declare-subtag! c super)
    (when (and (not (eq? sub super)) (memq sub ($ancestors c super)))
      (error 'declare-subtag! "that relation would close a cycle"
             (classifier-name c) sub super))
    (let ((old ($up c))
          (sups ($ancestors c super)))
      ;; TWO PHASES.  Every watcher validates against the proposed
      ;; closure and NOTHING commits until they all agree; only then do
      ;; they act on it.  Validating and committing watcher by watcher
      ;; would leave the ones that already ran holding tables computed
      ;; under a relation the next one is about to refuse -- and the
      ;; rollback below can put the closure back but not those tables.
      ($up! c (map (lambda (e)
                     (if (memq sub (cdr e))
                         (cons (car e) ($union (cdr e) sups))
                         e))
                   old))
      (guard (e (#t ($up! c old) (raise e)))
        (let validate ((l ($watchers c)))
          (unless (null? l)
            ((car l) 'validate 'declare-subtag!)
            (validate (cdr l)))))
      ;; Past validation the relation IS the new one, so the commit
      ;; phase does not undo it: its job is only to let each watcher
      ;; drop what it had cached under the old one.  A watcher that
      ;; fails here must not stop the others -- one of them still
      ;; holding a stale table is the very thing this phase exists to
      ;; prevent -- so every commit runs and the first failure is
      ;; raised afterwards.
      ;; `#f' cannot mean "nothing was raised": (raise #f) is legal, so
      ;; a watcher that raises it would be swallowed here and the next
      ;; failure would take its place.  The absence of a condition needs
      ;; a value no watcher can produce.
      (let commit ((l ($watchers c)) (err $none))
        (if (null? l)
            (unless (eq? err $none) (raise err))
            (let ((e (guard (x (#t x))
                       ((car l) 'commit 'declare-subtag!)
                       $none)))
              (commit (cdr l) (if (eq? err $none) e err)))))))

  (define (subtag? c a b)
    ($check-tag 'subtag? c a)
    ($check-tag 'subtag? c b)
    (and (memq b ($ancestors c a)) #t))

  ;; every tag that is a kind of this one, itself included
  (define (descendants c tag)
    ($check-tag 'descendants c tag)
    (let loop ((l ($tags c)) (acc '()))
      (cond ((null? l) (reverse acc))
            ((memq tag ($ancestors c (car l)))
             (loop (cdr l) (cons (car l) acc)))
            (else (loop (cdr l) acc)))))

  ;; The seam a dispatcher registers through.  `thunk' is called twice
  ;; per relation change: once as (thunk 'validate who), where raising
  ;; refuses the whole change, and -- only if every watcher agreed --
  ;; once as (thunk 'commit who) to act on it.  It exists because the
  ;; dependency runs one way (this library must not know what a generic
  ;; is) while a lattice change has to be able to invalidate one.
  (define (classifier-watch! c thunk)
    (unless (classifier? c) (error 'classifier-watch! "not a classifier" c))
    ($watchers! c (cons thunk ($watchers c))))

  ;; ---- the predicate relation ----
  ;; One global table: predicates are procedure objects, so there is
  ;; nothing to scope it to.
  (define $subsets '())

  (define ($supers p)
    (let ((e (assq p $subsets)))
      (if e (cdr e) (list p))))

  (define (declare-subset! sub super)
    (unless (procedure? sub)
      (error 'declare-subset! "a predicate is a procedure" sub))
    (unless (procedure? super)
      (error 'declare-subset! "a predicate is a procedure" super))
    (when (and (not (eq? sub super)) (memq sub ($supers super)))
      (error 'declare-subset! "that relation would close a cycle"
             sub super))
    (unless (assq sub $subsets)
      (set! $subsets (cons (cons sub (list sub)) $subsets)))
    (unless (assq super $subsets)
      (set! $subsets (cons (cons super (list super)) $subsets)))
    (let ((sups ($supers super)))
      (set! $subsets
            (map (lambda (e)
                   (if (memq sub (cdr e))
                       (cons (car e) ($union (cdr e) sups))
                       e))
                 $subsets))))

  (define (subset? a b) (and (memq b ($supers a)) #t))
  )
