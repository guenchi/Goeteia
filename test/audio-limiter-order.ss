;; expect: #t
;; The other order: play FIRST, configure the limiter after.
;;
;; ⭐ This is the file the design change exists for.  The bus used to be
;; born at the first limiter configuration, which left every sound
;; started before it permanently unlimited -- and for loop-sound!, which
;; has no natural end, "permanently" meant exactly that.  Moving the
;; bus's birth to whichever comes first, the first play or the first
;; configuration, is what fixed it.  ⚠️ A fix with no cell has no
;; evidence, and the cell has to be in this order: the configure-first
;; order (test/audio-limiter.ss) was green before the change too.
;;
;; It is a separate FILE rather than a separate section because
;; (aud sfx) keeps its context in module state that audio-init! sets
;; once and never clears.  One process is one context is one bus
;; lifetime.  ⛔ Reinstalling the mock does not undo it: the library
;; still holds the old context object, and cells written that way pass
;; or fail for reasons that have nothing to do with the library -- which
;; is how the first draft of this file behaved.
(import (rnrs) (web js) (audmock) (aud sfx))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))

(audio-mock-install!)
(audio-init!)
(define buf (js-eval "({id:'BUF'})"))
(audio-mock-reset!)

;; ---- a sound is already playing, with no limiter anywhere ----
(play! buf)
(define early (audio-newest-of-kind "SRC"))
(define early-edge (audio-target-of early))          ; the source's own edge
(define tail (audio-target-of early))                ; its volume gain
(define tail-edge (audio-target-of tail))            ; which reaches the bus
(check "LIM-INSERTED-AFTER: with no limiter, the sound reaches the destination"
       (equal? (audio-path-kinds early) '("SRC" "GAIN" "GAIN" "DEST")))

;; ---- LIM-INSERTED-AFTER ----
(audio-limiter!)
(check "LIM-INSERTED-AFTER: the sound already playing now runs through the limiter"
       (equal? (audio-path-kinds early) '("SRC" "GAIN" "GAIN" "COMP" "DEST")))
;; ⭐ and it happened without touching the voice: the source's edge and
;; its volume gain's edge are the ones they were.  This is the half that
;; distinguishes "the bus moved" from "every voice was rewired" -- both
;; produce the path above, and only one of them is the design.
(check "LIM-INSERTED-AFTER: the source was not rewired"
       (equal? (audio-target-of early) early-edge))
(check "LIM-INSERTED-AFTER: nor was its volume gain -- it was the bus that moved"
       (equal? (audio-target-of tail) tail-edge))

;; ---- LIM-DISABLE-REWIRE ----
;; Switching off has to reach the sounds already playing.  "Only affects
;; new sounds" is the plausible alternative, and for looping music it
;; means the switch never takes effect at all.
(define bus (audio-target-of tail))
(audio-limiter! #f)
(check "LIM-DISABLE-REWIRE: switching off takes the already-playing sound off the compressor"
       (equal? (audio-path-kinds early) '("SRC" "GAIN" "GAIN" "DEST")))
(check "LIM-DISABLE-REWIRE: the bus is what changed"
       (string=? "DEST" (audio-node-kind (audio-target-of bus))))
(check "LIM-DISABLE-REWIRE: and still no voice was rewired"
       (and (equal? (audio-target-of early) early-edge)
            (equal? (audio-target-of tail) tail-edge)))
;; a sound started after the switch is off behaves the same way
(play! buf)
(check "LIM-DISABLE-REWIRE: a sound started afterwards also bypasses"
       (equal? (audio-path-kinds (audio-newest-of-kind "SRC"))
               '("SRC" "GAIN" "GAIN" "DEST")))
(display (= failed 0))
