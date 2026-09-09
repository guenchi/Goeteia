;; expect: #t
;; The bus limiter: wiring and configuration, and nothing else.
;;
;; ⛔ These cells say nothing about how the limiter SOUNDS.  All green
;; means "the wiring and the configuration are right", not "the limiter
;; works".  Whether it is actually compressing is a question about
;; samples at two different drives, which an offline render can answer
;; -- a one-off reading of exactly that is in the design -- and which no
;; standing cell here does.  ⚠️ That is "not automated", not "not
;; possible": writing the second sentence where the first is true turns
;; a to-do into an impossibility, and nobody tries again.
;;
;; The rule these are written against, settled before any of it existed:
;;
;;   A voice's connection point is fixed when it starts; what that
;;   connection point feeds is not.  The bus is a unity gain made by
;;   whichever comes first -- the first play or the first limiter
;;   configuration -- and the switch changes what the BUS feeds.  One
;;   rewire, not one per voice.
;;
;; ⚠️ This file is the CONFIGURE-then-PLAY order only.  The other order
;; is test/audio-limiter-order.ss, and it is a separate file because
;; (aud sfx) keeps its context in module state that audio-init! sets
;; once and never clears: one process is one context is one bus
;; lifetime.  Two orders, two processes.  ⛔ Reinstalling the mock does
;; not undo it -- the library still holds the old context object, and a
;; cell written that way passes or fails for reasons that have nothing
;; to do with the library.
(import (rnrs) (web js) (audmock) (aud sfx))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (refuses? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))

(audio-mock-install!)
(audio-init!)
(define buf (js-eval "({id:'BUF'})"))
(audio-mock-reset!)

;; ---- LIM-INSERTED ----
;; Excludes "the configuration was stored and never wired up", which
;; COMPAT-NODES cannot see: it only looks at the graph with everything
;; switched off.
(audio-limiter!)
(play! buf)
(check "LIM-INSERTED: a sound played after the limiter is configured runs through it"
       (equal? (audio-path-kinds (audio-newest-of-kind "SRC"))
               '("SRC" "GAIN" "GAIN" "COMP" "DEST")))
(check "LIM-INSERTED: and it reaches the compressor through the bus, not directly"
       (string=? "GAIN" (audio-node-kind
                         (audio-target-of (audio-newest-of-kind "SRC")))))

;; ---- LIM-BEEP-BYPASS ----
;; A diagnostic tone must not be ducked by the gameplay limiter.  That
;; is true today because beep! builds its own graph straight to the
;; destination -- and nothing has ever pinned it, so it is true by
;; accident.  ⚠️ An accident and an unwritten decision look identical to
;; the next person who refactors; this is what makes it a decision.
(beep! 440.0 0.1)
(check "LIM-BEEP-BYPASS: a beep goes straight to the destination"
       (equal? (audio-path-kinds (audio-newest-of-kind "OSC"))
               '("OSC" "GAIN" "DEST")))
(check "LIM-BEEP-BYPASS: while a played sound, at the same moment, does not"
       (equal? (audio-path-kinds (audio-newest-of-kind "SRC"))
               '("SRC" "GAIN" "GAIN" "COMP" "DEST")))

;; ---- LIM-PARAMS ----
;; Five values, each different from the other four AND from its own
;; default: with two equal, a swap between them reads as a pass, and
;; with one at its default an omission reads as a pass.  (Defaults are
;; -6, 0, 20, 0.003, 0.25.)
;; ⛔ No log reset here.  Resetting would drop the connect that names
;; the compressor, and audio-newest-of-kind would answer "no-such-node"
;; -- a cell that then compares 'unset against every expected value and
;; reds for a reason that has nothing to do with the library.  The
;; reader below keeps the LAST write to each parameter, so an earlier
;; configuration in this file cannot be mistaken for this one.
(audio-limiter! -12.5 7.25 3.5 0.017 0.625)
(define comp (audio-newest-of-kind "COMP"))
(define (param-written node name)
  (let loop ((i 0) (v 'unset))
    (cond ((>= i (audio-log-length)) v)
          ((and (string=? (audio-op i) "param.value")
                (equal? (audio-arg i 0) node)
                (equal? (audio-arg i 1) name))
           (loop (+ i 1) (audio-arg-num i 2)))
          (else (loop (+ i 1) v)))))
(check "LIM-PARAMS: every configured value lands on its own parameter"
       (and (equal? -12.5 (param-written comp "threshold"))
            (equal? 7.25  (param-written comp "knee"))
            (equal? 3.5   (param-written comp "ratio"))
            (equal? 0.017 (param-written comp "attack"))
            (equal? 0.625 (param-written comp "release"))))

;; ---- LIM-REFUSE, with its green twin ----
;; ⭐ A rejection rule needs a passing twin, and the twin has to look
;; like something that ought to be rejected -- otherwise the pair says
;; nothing that the rejection alone did not.  Both ends below are legal
;; and both are what a "tighten this up" edit would take away: ratio 1.0
;; is no compression at all, threshold 0.0 is the very top of the range.
(check "LIM-REFUSE: ratio 1.0 is legal -- the ends of the range are inside it"
       (not (refuses? (lambda () (audio-limiter! -6.0 0.0 1.0 0.003 0.25)))))
(check "LIM-REFUSE: threshold 0.0 is legal too"
       (not (refuses? (lambda () (audio-limiter! 0.0 0.0 20.0 0.003 0.25)))))
(check "LIM-REFUSE: and the far ends of knee and both time constants"
       (and (not (refuses? (lambda () (audio-limiter! -100.0 40.0 20.0 0.0 0.0))))
            (not (refuses? (lambda () (audio-limiter! -6.0 0.0 20.0 1.0 1.0))))))
(check "LIM-REFUSE: past an end is refused, in every position"
       (and (refuses? (lambda () (audio-limiter! -100.5 0.0 20.0 0.003 0.25)))
            (refuses? (lambda () (audio-limiter! 0.5 0.0 20.0 0.003 0.25)))
            (refuses? (lambda () (audio-limiter! -6.0 -0.5 20.0 0.003 0.25)))
            (refuses? (lambda () (audio-limiter! -6.0 40.5 20.0 0.003 0.25)))
            (refuses? (lambda () (audio-limiter! -6.0 0.0 0.5 0.003 0.25)))
            (refuses? (lambda () (audio-limiter! -6.0 0.0 20.5 0.003 0.25)))
            (refuses? (lambda () (audio-limiter! -6.0 0.0 20.0 -0.5 0.25)))
            (refuses? (lambda () (audio-limiter! -6.0 0.0 20.0 1.5 0.25)))
            (refuses? (lambda () (audio-limiter! -6.0 0.0 20.0 0.003 1.5)))))
;; ⚠️ A NaN passes a range check written with fl<?, because every
;; comparison with it is false.  It has to be excluded by name, and a
;; cell that only tried out-of-range values would never say so.
(check "LIM-REFUSE: a NaN is refused, in every position"
       (let ((nan (fl/ 0.0 0.0)))
         (and (refuses? (lambda () (audio-limiter! nan 0.0 20.0 0.003 0.25)))
              (refuses? (lambda () (audio-limiter! -6.0 nan 20.0 0.003 0.25)))
              (refuses? (lambda () (audio-limiter! -6.0 0.0 nan 0.003 0.25)))
              (refuses? (lambda () (audio-limiter! -6.0 0.0 20.0 nan 0.25)))
              (refuses? (lambda () (audio-limiter! -6.0 0.0 20.0 0.003 nan))))))
;; ⭐ A partial argument list must be refused rather than read as a
;; prefix.  Accepting a short call turns "one argument missing" into
;; every later argument silently shifted by one -- which is the exact
;; mistake LIM-PARAMS exists to catch, so tolerating it here opens a
;; door straight past that cell.
(check "LIM-REFUSE: a partial argument list is refused, not read as a prefix"
       (and (refuses? (lambda () (audio-limiter! -6.0 0.0)))
            (refuses? (lambda () (audio-limiter! -6.0 0.0 20.0)))
            (refuses? (lambda () (audio-limiter! -6.0 0.0 20.0 0.003)))))
(display (= failed 0))
