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

;; Fine-grained reactivity: signals, effects, batching.
(library (web reactive)
  (export signal signal-ref signal-set! signal-update!
          effect dispose-effect! on-cleanup root batch untracked)
  (import (rnrs))

  ;; a signal holds a value and the effects that read it;
  ;; an effect holds its thunk and the signals it read last run
  (define-record-type ($sig $make-sig $sig?)
    (fields (mutable v $sig-v $sig-v!)
            (mutable subs $sig-subs $sig-subs!)))
  (define-record-type ($eff $make-eff $eff?)
    (fields (mutable thunk $eff-thunk $eff-thunk!)
            (mutable deps $eff-deps $eff-deps!)
            (mutable live $eff-live $eff-live!)
            ;; effects created during this effect's run: they die with
            ;; it and are re-created fresh on every rerun
            (mutable kids $eff-kids $eff-kids!)
            ;; thunks this run registered with on-cleanup, newest
            ;; first -- the list order IS the order they run in
            (mutable cleanups $eff-cleanups $eff-cleanups!)))

  (define $current #f)                  ; the effect being (re)run
  (define $batch-depth 0)
  (define $queue '())                   ; effects awaiting a batch flush

  (define (signal init) ($make-sig init '()))

  (define (signal-ref s)
    ;; an owner made by `root` has no thunk: it collects kids for
    ;; disposal but never subscribes
    (when (and $current ($eff-thunk $current))
      (unless (memq $current ($sig-subs s))
        ($sig-subs! s (cons $current ($sig-subs s)))
        ($eff-deps! $current (cons s ($eff-deps $current)))))
    ($sig-v s))

  (define (signal-set! s v)
    (unless (eqv? v ($sig-v s))
      ($sig-v! s v)
      (let ((subs ($sig-subs s)))
        (if (< 0 $batch-depth)
            (for-each (lambda (e)
                        (unless (memq e $queue)
                          (set! $queue (cons e $queue))))
                      subs)
            (for-each $run-effect subs)))))
  (define (signal-update! s f)
    (signal-set! s (f (signal-ref s))))

  (define ($detach! e)
    (for-each (lambda (s) ($sig-subs! s (remq e ($sig-subs s))))
              ($eff-deps e))
    ($eff-deps! e '()))

  ;; "nothing was raised" needs a value no thunk can raise, and #f is
  ;; not one: (raise #f) is legal, and a cleanup that raised it would
  ;; be read as a quiet return.  A raised #f is passed on unchanged.
  (define $no-cond (list 'no-condition))
  (define ($first held c) (if (eq? held $no-cond) c held))

  ;; #t while a cleanup thunk is on the stack.  on-cleanup consults it
  ;; rather than $current, because $current during a cleanup is
  ;; whatever the DISPOSER was running under -- at top level #f, but
  ;; inside another effect that effect, and registering this run's
  ;; leftovers on an unrelated live effect is worse than refusing.
  (define $in-cleanup #f)

  ;; Run one cleanup thunk, holding the first condition raised across
  ;; the whole release rather than letting it escape.  Every thunk
  ;; gets its turn: the caller still hears about the failure, but one
  ;; bad thunk cannot strand the sockets the others were to close.
  (define ($run-cleanup held thunk)
    (let ((prev $in-cleanup))
      (dynamic-wind
        (lambda () (set! $in-cleanup #t))
        (lambda () (guard (c (#t ($first held c))) (thunk) held))
        (lambda () (set! $in-cleanup prev)))))

  ;; Release what e owns: its children's subtrees first, so a nested
  ;; resource is freed before the one it was opened inside, then e's
  ;; own cleanups newest-registration first.  Nothing raises out of
  ;; here -- the first condition is returned, and one caller at the
  ;; top of the release re-raises it once the WHOLE tree has run.
  ;; Releasing a tree is one transaction; a child that raises must not
  ;; cost its siblings, or its parent, their turn.
  ;;
  ;; Each list is emptied before it is walked, so a dispose or a rerun
  ;; triggered from inside a cleanup cannot run any of these a second
  ;; time.
  (define ($release! e held)
    (let ((ks ($eff-kids e))
          (cs ($eff-cleanups e)))
      ($eff-kids! e '())
      ($eff-cleanups! e '())
      (let ((held (let loop ((l ks) (held held))
                    (if (null? l) held (loop (cdr l) ($kill! (car l) held))))))
        (let loop ((l cs) (held held))
          (if (null? l) held (loop (cdr l) ($run-cleanup held (car l))))))))

  (define ($kill! e held)
    ($eff-live! e #f)
    ($detach! e)
    ($release! e held))

  ;; The one place the held condition turns back into a raise, at the
  ;; top of a release and nowhere inside it.  Every entry that starts
  ;; a release ends with this.
  (define ($raise-held held)
    (unless (eq? held $no-cond) (raise held)))

  ;; Registered during a run, for the end of that run.  With no run to
  ;; end -- outside every effect, or from inside a cleanup, which IS
  ;; the end of one -- this is an error by name rather than a thunk
  ;; quietly dropped on the floor.  A root body counts as a run: its
  ;; owner holds the thunk until the root's disposer fires.
  (define (on-cleanup thunk)
    (when $in-cleanup
      (error 'on-cleanup "a cleanup is running; that run has already ended"))
    (unless $current
      (error 'on-cleanup "no effect is running; nothing to clean up after"))
    ($eff-cleanups! $current (cons thunk ($eff-cleanups $current))))

  ;; A rerun ends the previous run before it starts the next: the
  ;; children die, the cleanups run, and only then does the new body
  ;; go.  Two things a cleanup can do that the body must survive:
  ;; raise (the condition comes out here, and this rerun is over --
  ;; the same report dispose-effect! would give), and dispose this
  ;; very effect (or an ancestor), which is why liveness is asked
  ;; again rather than assumed from the check at the top.
  (define ($run-effect e)
    (when ($eff-live e)
      ($detach! e)
      ($raise-held ($release! e $no-cond))
      (when ($eff-live e)
        (let ((prev $current)
              (prevc $in-cleanup))
          (dynamic-wind
            (lambda () (set! $current e) (set! $in-cleanup #f))
            ($eff-thunk e)
            (lambda () (set! $current prev) (set! $in-cleanup prevc)))))))

  (define (effect thunk)
    (let ((e ($make-eff thunk '() #t '() '())))
      (when $current
        ($eff-kids! $current (cons e ($eff-kids $current))))
      ($run-effect e)
      e))
  (define (dispose-effect! e)
    ($raise-held ($kill! e $no-cond)))

  ;; run thunk under a fresh detached owner: effects created inside
  ;; survive reruns of the enclosing effect and die only through the
  ;; returned disposer.  Yields (result . dispose).
  (define (root thunk)
    (let ((owner ($make-eff #f '() #t '() '()))
          (prev $current)
          (prevc $in-cleanup))
      (dynamic-wind
        (lambda () (set! $current owner) (set! $in-cleanup #f))
        ;; The disposer takes the internal path rather than calling
        ;; the exported dispose-effect!, which it would otherwise be
        ;; the only caller of: a top-level reachable only from inside
        ;; a closure this library hands out can be dropped before the
        ;; body that calls it is compiled, and the program then fails
        ;; to build with "cannot call: dispose-effect!".  Behaviour is
        ;; the same; $raise-held keeps the rule stated once.
        (lambda () (cons (thunk)
                         (lambda () ($raise-held ($kill! owner $no-cond)))))
        (lambda () (set! $current prev) (set! $in-cleanup prevc)))))

  (define (batch thunk)
    (set! $batch-depth (+ $batch-depth 1))
    (let ((r (dynamic-wind
               (lambda () #f)
               thunk
               (lambda ()
                 (set! $batch-depth (- $batch-depth 1))
                 (when (zero? $batch-depth)
                   (let ((q (reverse $queue)))
                     (set! $queue '())
                     (for-each $run-effect q)))))))
      r))

  (define (untracked thunk)
    (let ((prev $current))
      (dynamic-wind
        (lambda () (set! $current #f))
        thunk
        (lambda () (set! $current prev))))))
