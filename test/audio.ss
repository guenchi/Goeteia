;; expect: #t
;; (aud sfx) against the recording mock: init is idempotent, beeps wire
;; oscillator->gain->destination with a click-free fade, loads run the
;; fetch/decode chain (synchronous thenables stand in for promises),
;; buffer playback sets volume, rate and looping -- and the default
;; graph is exactly the nodes it is allowed to have.
;;
;; ⚠️ This file used to carry its own inline mock, in which every gain
;; came back with the id "GAIN".  That mock could say a gain connected
;; to a gain; it could not say WHICH, and a voice now passes through
;; three of them (volume, bus, and with panning two more plus a
;; merger).  The whitelist below is unwritable in a log like that: it
;; cannot even answer how many distinct gains exist.  ⭐ The mock was
;; not broken -- it was built for a smaller question, and we started
;; asking one it had no words for.  It now shares test/lib/audmock.ss
;; with the other audio files, which is also one instrument instead of
;; two that drift.
(import (rnrs) (web js) (audmock) (aud sfx))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
;; ⚠️ Counting is done FROM a mark rather than after a reset wherever
;; the graph is also being read.  audio-mock-reset! empties the log, and
;; in this instrument the log IS the graph -- an edge made before the
;; reset is not merely unlisted, it is gone, so a path that crosses it
;; stops early.  A section that wants both a fresh count and a whole
;; graph has to take a mark, not a reset.
(define (op-count-from mark op)
  (let loop ((i mark) (n 0))
    (cond ((>= i (audio-log-length)) n)
          ((string=? (audio-op i) op) (loop (+ i 1) (+ n 1)))
          (else (loop (+ i 1) n)))))
(define (op-count op) (op-count-from 0 op))
(define (param-of node name)            ; last value written to one param
  (let loop ((i 0) (v 'unset))
    (cond ((>= i (audio-log-length)) v)
          ((and (string=? (audio-op i) "param.value")
                (equal? (audio-arg i 0) node) (equal? (audio-arg i 1) name))
           (loop (+ i 1) (audio-arg-num i 2)))
          (else (loop (+ i 1) v)))))


(audio-mock-install!)
;; ⭐ The mark is taken BEFORE audio-init!, and that position is the
;; whole cell.  Creating the context is one of the things under
;; suspicion here -- the rule is that the bus is made by the first play
;; or the first limiter configuration and NOT by the context coming into
;; being -- so init has to fall inside the window being observed.  A
;; mark taken after it puts the accused outside the evidence.
;;
;; ⚠️ Measured twice, wrongly twice, before this line was right.  The
;; first version counted connect entries in the log, and the reset below
;; erased the edge that would have shown the extra node.  The second
;; counted creations but marked after init, so the subtraction removed
;; the same node again.  ⭐ Both times the evidence happened before it
;; was observed -- once erased by a reset, once cancelled by a minus --
;; and both times the repair swapped the mechanism that had just been
;; named while leaving the moment wrong.  The reading that settles it is
;; the mutant's, not the argument's.
(define nodes-before-beeps (audio-nodes-created))
(audio-init!)
(audio-init!)
(check "one context, one resume, however many times init is called"
       (and (= 1 (op-count "resume")) (= 0.0 (audio-time))))
(audio-mock-reset!)

;; ---- beeps ----
(define osc (beep! 440 0.5))
(check "a beep is an oscillator through a gain to the destination"
       (equal? (audio-path-kinds (audio-newest-of-kind "OSC")) '("OSC" "GAIN" "DEST")))
(check "with a click-free fade: set, then ramp to near zero at the end"
       (and (= 1 (op-count "param.setValueAtTime"))
            (= 1 (op-count "param.linearRamp"))
            (= 0.3 (audio-arg-num (audio-find "param.setValueAtTime") 2))
            (= 0.5 (audio-arg-num (audio-find "param.linearRamp") 3))))
(check "and it is started and stopped at the times it was given"
       (and (= 0.0 (audio-arg-num (audio-find "start") 1))
            (= 0.5 (audio-arg-num (audio-find "stop") 1))))
(check "the requested tone reaches the oscillator"
       (and (string=? "square" (js->string (js-get osc "type")))
            (= 440 (js->number (js-get (js-get osc "frequency") "value")))))
(define osc2 (beep! 880 0.25 0.2 "sine"))
(check "options: a different wave and a different volume"
       (and (string=? "sine" (js->string (js-get osc2 "type")))
            (= 880 (js->number (js-get (js-get osc2 "frequency") "value")))
            (= 0.2 (audio-arg-num (audio-find-from "param.setValueAtTime"
                                                   (+ 1 (audio-find "param.setValueAtTime")))
                                  2))))
;; ⭐ Two beeps and nothing else: four nodes, no bus.  The bus is made
;; by the first play or the first limiter configuration -- NOT by the
;; context coming into being.  Hanging its creation on the context
;; would put an extra node in the graph of a program that only ever
;; beeps, and this is the cell that says so.
;;
;; ⚠️ It counts CREATIONS, taken from a mark, and not connect entries in
;; the log.  The first version counted the log and could not see the
;; mutant it was written for: the bus built during audio-init! had its
;; connect cleared by the reset above, so the count came out at exactly
;; the expected four.  ⛔ The comment then claiming "this is the cell
;; that would say so" was false, and it was the only thing telling
;; anyone the constraint was watched.
;;
;; ⚠️ The numbers this cell actually reads, on the mutant that builds
;; the bus during audio-init!: delta 5 against the 4 asserted.  ⛔ Not
;; "creations answer 5, log entries answer 4" -- that was true of the
;; absolute count and this cell uses a difference, so every number in it
;; was right and none of them was about this cell.  A reading that is
;; correct and wired to the wrong quantity is harder to catch than an
;; assertion with no reading at all.
(check "beeping does not build a bus"
       (= 4 (- (audio-nodes-created) nodes-before-beeps)))

;; ---- load: fetch -> arrayBuffer -> decode -> k ----
(audio-mock-reset!)
(define got #f)
(load-sound! "hit.ogg" (lambda (buf) (set! got buf)))
(check "the load chain runs once and reaches the continuation"
       (and (js-ref? got)
            (string=? "BUF" (js->string (js-get got "id")))
            (= 1 (op-count "fetch"))
            (= 1 (op-count "decode"))
            (equal? "hit.ogg" (audio-arg (audio-find "fetch") 0))))

;; ---- playback, and the whitelist ----
;; ⚠️ COMPAT-NODES, narrowed.  It used to say only "no extra nodes",
;; which a bus at unity would fail while a bus quietly doubling as a
;; master volume would pass just as well.  Naming the nodes AND pinning
;; the bus at 1.0 is the stronger statement, and it is the one that
;; catches an implementation that reaches for the bus as a volume
;; control later.
(audio-mock-reset!)
(define src (play! got 0.5 1.2))
(define voice (audio-newest-of-kind "SRC"))
(define volume (audio-target-of voice))
(define bus (audio-target-of volume))
(check "COMPAT-NODES: the default path is source, volume gain, bus, destination"
       (equal? (audio-path-kinds voice) '("SRC" "GAIN" "GAIN" "DEST")))
(check "COMPAT-NODES: the volume gain carries the volume that was asked for"
       (= 0.5 (param-of volume "gain")))
(check "COMPAT-NODES: and the bus is at unity -- it is a bus, not a master volume"
       (= 1.0 (param-of bus "gain")))
(check "COMPAT-NODES: the bus goes straight to the destination"
       (string=? "DEST" (audio-node-kind (audio-target-of bus))))
(check "playback: the buffer, the rate, and looping only when asked"
       (and (string=? "BUF" (js->string (js-get (js-get src "buffer") "id")))
            (let ((r (js->number (js-get (js-get src "playbackRate") "value"))))
              (and (< 1.19 r) (< r 1.21)))
            (not (js-truthy? (js-get src "loop")))))

;; ---- looping music, and stopping it ----
(define mark (audio-log-length))
(define music (loop-sound! got 0.4))
(check "music loops" (js-truthy? (js-get music "loop")))
(stop-sound! music)
(check "and stopping it stops the source" (= 1 (op-count-from mark "stop")))
(check "music takes the same path as an effect"
       (equal? (audio-path-kinds (audio-newest-of-kind "SRC"))
               '("SRC" "GAIN" "GAIN" "DEST")))
(display (= failed 0))
