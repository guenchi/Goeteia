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

;; What a set of sources adds up to, and whose contribution is whose.
;;
;; A modifier is one source's claim about one attribute: this ring gives
;; +12 armour, this spell gives -0.3 speed for eight seconds.  The
;; library keeps the claims and answers the total.
;;
;; SOURCE OWNERSHIP IS THE POINT.  A source may hold at most one claim
;; on an attribute, so applying the same source again REPLACES its own
;; claim and leaves every other source alone.  Without that, the natural
;; implementation of "refresh this effect" is remove-then-add, and every
;; caller writes it slightly differently: some forget the remove and
;; stack the thing with itself, some remove too much.  Here it is one
;; call that cannot do either.
;;
;; WHY THIS IS NOT PART OF (gam stats).  A pool has one current value
;; and a maximum; an attribute here has no value of its own at all --
;; it is only ever the sum of what is claimed about it right now.  More
;; to the point, (gam stats) says in its own header that it deliberately
;; holds no timer, because a timed state living there would make
;; stats-damage! depend on a clock that library does not own.  Modifiers
;; expire.  They belong on the other side of that line, with the clock
;; in plain sight in modifier-tick!.
;;
;; WHY IT IS NOT (gam effects) EITHER.  That answers "is this state on,
;; and for how much longer".  This answers "what does everything come
;; to, and whose is it".  A caller can want both about the same spell
;; and they are not derivable from one another: effects has no notion of
;; a magnitude to add up, and nothing here says whether a state is on.
;;
;; STACKING IS TWO RULES AND THE CALLER PICKS PER CLAIM.  A claim with
;; no group ADDS.  Claims sharing a group are mutually exclusive and
;; only the largest magnitude counts -- largest by absolute value, so
;; the strongest penalty wins among penalties exactly as the strongest
;; bonus wins among bonuses.  Groups are compared independently of each
;; other and then added, so "the best of these three, plus the best of
;; those two, plus everything ungrouped" is what comes out.
;;
;; THE MULTIPLICATIVE PART IS THE CALLER'S TABLE, NOT OURS.  Some
;; designs want an attribute whose total is scaled by a second
;; attribute, itself modifiable.  Which attribute scales which is a
;; question about a particular design, so make-modifiers takes a
;; procedure that answers it and there is no built-in mapping at all.
;; A fixed list here would be the worst of the options: an attribute
;; nobody thought to add to it gets no scaling and nothing says so, and
;; the failure is a number that is quietly too small forever.  With no
;; procedure, nothing is scaled -- which is a rule a reader can state,
;; unlike the contents of a list.
;;
;; The scaling is applied ONE level deep: the scale attribute's own
;; total is read with the same stacking rules, but it is not itself
;; scaled, even if the procedure names a scale for it.  A caller whose
;; procedure answers an attribute with itself gets that attribute
;; scaled by its own total once, which is arithmetic rather than a loop.
(library (gam modifiers)
  (export make-modifiers modifiers? modifier-set! modifier-remove-source!
          modifier-ref modifier-tick! modifier-dispel! modifier-clear!
          modifier-entries modifier-entry? modifier-entry-source
          modifier-entry-attribute modifier-entry-value
          modifier-entry-remaining modifier-entry-group
          modifier-entry-dispellable?)
  (import (rnrs))

  ;; #(gam-modifiers rows scale-of); rows newest first
  (define ($m? m)
    (and (vector? m) (= (vector-length m) 3)
         (eq? (vector-ref m 0) 'gam-modifiers)))
  (define ($need-m who m)
    (unless ($m? m) (error who "not a modifier set" m)))
  (define ($rows m) (vector-ref m 1))
  (define ($rows! m v) (vector-set! m 1 v))
  (define ($scale-of m) (vector-ref m 2))

  ;; #(gam-modifier source attribute value remaining group dispellable)
  ;;
  ;; `remaining' is #f for a claim that does not expire, and a positive
  ;; real otherwise.  The two are kept apart rather than using a large
  ;; number for "forever", because a caller displaying the remaining
  ;; time has to be able to tell the difference and a sentinel number
  ;; would eventually be reached.
  (define ($e? e)
    (and (vector? e) (= (vector-length e) 7)
         (eq? (vector-ref e 0) 'gam-modifier)))
  (define ($need-e who e)
    (unless ($e? e) (error who "not a modifier entry" e)))
  (define ($src e) (vector-ref e 1))
  (define ($attr e) (vector-ref e 2))
  (define ($val e) (vector-ref e 3))
  (define ($left e) (vector-ref e 4))
  (define ($left! e v) (vector-set! e 4 v))
  (define ($group e) (vector-ref e 5))
  (define ($disp e) (vector-ref e 6))

  (define (modifiers? m) ($m? m))
  (define (modifier-entry? e) ($e? e))

  (define (make-modifiers . rest)
    (let ((scale-of (if (null? rest) #f (car rest))))
      (unless (or (not scale-of) (procedure? scale-of))
        (error 'make-modifiers
               "the scale mapping is a procedure of an attribute, or #f"
               scale-of))
      (vector 'gam-modifiers '() scale-of)))

  ;; The entries as they stand, newest first.  They are opaque: read
  ;; them with the accessors below rather than by position, which is the
  ;; whole reason the accessors exist.
  (define (modifier-entries m) ($need-m 'modifier-entries m) ($rows m))

  (define (modifier-entry-source e) ($need-e 'modifier-entry-source e) ($src e))
  (define (modifier-entry-attribute e) ($need-e 'modifier-entry-attribute e) ($attr e))
  (define (modifier-entry-value e) ($need-e 'modifier-entry-value e) ($val e))
  (define (modifier-entry-remaining e) ($need-e 'modifier-entry-remaining e) ($left e))
  (define (modifier-entry-group e) ($need-e 'modifier-entry-group e) ($group e))
  (define (modifier-entry-dispellable? e) ($need-e 'modifier-entry-dispellable? e) ($disp e))

  ;; Duration, group and dispellability are optional and default to
  ;; "forever, on its own, and not dispellable", which is the plainest
  ;; claim there is.  Every position is type-checked, which catches an
  ;; argument in the wrong place except between the two that are both
  ;; plain symbols: source and attribute cannot be told apart by
  ;; anything this library can see, so those two are on the caller.
  (define (modifier-set! m source attribute value . rest)
    ($need-m 'modifier-set! m)
    (let ((seconds (if (null? rest) #f (car rest)))
          (group (if (or (null? rest) (null? (cdr rest))) #f (cadr rest)))
          (dispellable (if (or (null? rest) (null? (cdr rest)) (null? (cddr rest)))
                           #f
                           (caddr rest))))
      (unless (symbol? source)
        (error 'modifier-set! "a source is a symbol" source))
      (unless (symbol? attribute)
        (error 'modifier-set! "an attribute is a symbol" attribute))
      (unless (real? value)
        (error 'modifier-set! "a modifier value is a real" attribute value))
      (unless (or (not seconds) (and (real? seconds) (< 0 seconds)))
        (error 'modifier-set! "a duration is a positive real, or #f for forever"
               attribute seconds))
      (unless (or (not group) (symbol? group))
        (error 'modifier-set! "an exclusive group is a symbol, or #f" group))
      (unless (boolean? dispellable)
        (error 'modifier-set! "dispellable is #t or #f" dispellable))
      ($rows! m (cons (vector 'gam-modifier source attribute value
                              seconds group dispellable)
                      (let drop ((l ($rows m)))
                        (cond ((not (pair? l)) '())
                              ((and (eq? source ($src (car l)))
                                    (eq? attribute ($attr (car l))))
                               (drop (cdr l)))
                              (else (cons (car l) (drop (cdr l))))))))))

  (define (modifier-remove-source! m source)
    ($need-m 'modifier-remove-source! m)
    (unless (symbol? source)
      (error 'modifier-remove-source! "a source is a symbol" source))
    ($rows! m (let keep ((l ($rows m)))
                (cond ((not (pair? l)) '())
                      ((eq? source ($src (car l))) (keep (cdr l)))
                      (else (cons (car l) (keep (cdr l))))))))

  ;; The ungrouped claims are summed; each group contributes only its
  ;; largest magnitude.  Ties go to the one already held, which is the
  ;; later-applied claim, because rows are newest first.
  (define ($base m attribute)
    (let walk ((l ($rows m)) (total 0) (groups '()))
      (if (not (pair? l))
          (let add ((g groups) (sum total))
            (if (not (pair? g)) sum (add (cdr g) (+ sum (cdar g)))))
          (let ((e (car l)))
            (cond
             ((not (eq? attribute ($attr e))) (walk (cdr l) total groups))
             ((not ($group e)) (walk (cdr l) (+ total ($val e)) groups))
             (else
              (let ((old (assq ($group e) groups)))
                (if (and old (not (< (abs (cdr old)) (abs ($val e)))))
                    (walk (cdr l) total groups)
                    (walk (cdr l) total
                          (cons (cons ($group e) ($val e))
                                (let drop ((g groups))
                                  (cond ((not (pair? g)) '())
                                        ((eq? ($group e) (caar g)) (drop (cdr g)))
                                        (else (cons (car g) (drop (cdr g)))))))))))))))) 

  ;; An attribute nothing has claimed answers zero rather than raising:
  ;; the absence of every modifier is a state a caller reaches by doing
  ;; nothing at all, and it has an obvious right answer.
  (define (modifier-ref m attribute)
    ($need-m 'modifier-ref m)
    (unless (symbol? attribute)
      (error 'modifier-ref "an attribute is a symbol" attribute))
    (let* ((base ($base m attribute))
           (scale-of ($scale-of m))
           (scale (and scale-of (scale-of attribute))))
      (unless (or (not scale) (symbol? scale))
        (error 'modifier-ref
               "the scale mapping answered something that is not an attribute"
               attribute scale))
      (if scale (* base (+ 1 ($base m scale))) base)))

  ;; Claims with no duration are left alone; the rest count down and are
  ;; dropped at zero.  Reaching exactly zero drops the claim, because a
  ;; modifier with no time left is not one that still applies for an
  ;; instant.
  (define (modifier-tick! m dt)
    ($need-m 'modifier-tick! m)
    (unless (and (real? dt) (not (< dt 0)))
      (error 'modifier-tick! "an elapsed time is a non-negative real" dt))
    (let step ((l ($rows m)))
      (when (pair? l)
        (when ($left (car l)) ($left! (car l) (- ($left (car l)) dt)))
        (step (cdr l))))
    ($rows! m (let keep ((l ($rows m)))
                (cond ((not (pair? l)) '())
                      ((and ($left (car l)) (not (< 0 ($left (car l)))))
                       (keep (cdr l)))
                      (else (cons (car l) (keep (cdr l))))))))

  ;; Drops what was marked dispellable and nothing else.  A claim's
  ;; dispellability is decided where it is applied rather than here,
  ;; because the same attribute can be granted by something that may be
  ;; stripped and by something that may not.
  (define (modifier-dispel! m)
    ($need-m 'modifier-dispel! m)
    ($rows! m (let keep ((l ($rows m)))
                (cond ((not (pair? l)) '())
                      (($disp (car l)) (keep (cdr l)))
                      (else (cons (car l) (keep (cdr l))))))))

  (define (modifier-clear! m) ($need-m 'modifier-clear! m) ($rows! m '())))
