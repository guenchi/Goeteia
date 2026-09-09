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

;; Game audio over the WebAudio bridge: procedural beeps (no asset
;; files needed), decoded samples, and looping music.
;;
;;   (audio-init!)                        ; once, AFTER a user gesture
;;   (beep! 440 0.1)                      ; a blip: freq (Hz), duration (s)
;;   (beep! 880 0.05 0.2 "sine")          ; volume and waveform
;;   (load-sound! "hit.ogg"
;;     (lambda (buf) (set! hit buf)))     ; fetch + decode, then k
;;   (play! hit)                          ; fire and forget
;;   (play! hit 0.5 1.2)                  ; volume, playback rate
;;   (define music (loop-sound! bgm 0.4))
;;   (stop-sound! music)
;;
;; Browsers refuse to start audio before the user interacts with the
;; page, so call audio-init! from the first click/keydown -- games
;; have a "click to start" moment anyway.  Everything else errors
;; loudly until then.
;;
(library (aud sfx)
  (export audio-init! audio-time
          beep! load-sound! play! loop-sound! stop-sound!
          audio-voices! audio-voice-count)
  (import (rnrs) (web js) (aud mix))

  (define $audio-ctx #f)

  (define ($audio-ctx!)
    (unless $audio-ctx
      (error 'audio "call audio-init! first (after a user gesture)"))
    $audio-ctx)

  ;; Idempotent.  With no argument this makes the real context and
  ;; resumes it, because one created before the user's gesture starts
  ;; suspended.
  ;;
  ;; With a factory, the CALLER owns the context: the library calls the
  ;; factory (it decides when a context is needed) and then leaves the
  ;; state alone -- not one resume.  That is how an OfflineAudioContext
  ;; gets in, and resuming one would be meaningless.
  ;;
  ;; The branch is on the ARGUMENT, deliberately, rather than on
  ;; sniffing what came back.  Testing constructor.name or probing for
  ;; a method would tie our behaviour to how the platform happens to
  ;; name its types -- one more piece of platform semantics we would be
  ;; assuming instead of being told.  Here the caller says which it is,
  ;; and the recording of an injected run contains no resume at all,
  ;; which is a fact a test can read rather than a belief.
  (define (audio-init! . factory)
    (unless $audio-ctx
      (if (pair? factory)
          (set! $audio-ctx ((car factory)))
          (begin
            (set! $audio-ctx
                  (js-eval
                   "new (globalThis.AudioContext || globalThis.webkitAudioContext)()"))
            (js-method $audio-ctx "resume"))))
    $audio-ctx)

  (define (audio-time)                  ; seconds, for scheduling
    (js->number (js-get ($audio-ctx!) "currentTime")))

  ;; an oscillator blip with a linear fade, so notes end without a
  ;; click; returns the oscillator
  (define (beep! freq dur . opt)
    (let* ((vol (if (null? opt) 0.3 (car opt)))
           (type (if (or (null? opt) (null? (cdr opt)))
                     "square"
                     (cadr opt)))
           (ctx ($audio-ctx!))
           (t0 (js->number (js-get ctx "currentTime")))
           (t1 (+ t0 dur))
           (osc (js-method ctx "createOscillator"))
           (g (js-method ctx "createGain"))
           (gain (js-get g "gain")))
      (js-set! osc "type" type)
      (js-set! (js-get osc "frequency") "value" freq)
      (js-method gain "setValueAtTime" vol t0)
      (js-method gain "linearRampToValueAtTime" 0.0001 t1)
      (js-method osc "connect" g)
      (js-method g "connect" (js-get ctx "destination"))
      (js-method osc "start" t0)
      (js-method osc "stop" t1)
      osc))

  ;; fetch + decodeAudioData; k receives the decoded buffer.  The
  ;; chain is plain .then callbacks -- no JSPI needed, loading can
  ;; start before any user gesture (only PLAYING needs the context)
  (define (load-sound! url k)
    (let ((resp (js-call (js-get (js-global) "fetch") (js-undefined) url)))
      (js-method
       (js-method resp "then"
                  (lambda (r) (js-method r "arrayBuffer")))
       "then"
       (lambda (ab)
         (js-method (js-method ($audio-ctx!) "decodeAudioData" ab)
                    "then"
                    (lambda (buf) (k buf) (js-undefined)))
         (js-undefined)))))

  ;; ---- the voice pool ----
  ;;
  ;; Off unless a cap is set.  Turning it on is a decision with an
  ;; audible consequence -- sounds that used to overlap start cutting
  ;; each other off -- so it is not something a caller gets by
  ;; upgrading.
  ;;
  ;; A pooled voice carries one extra gain of its own, used only to
  ;; fade it out when it is evicted.  That node exists only while the
  ;; pool does: with the pool off the chain is what it always was,
  ;; which is what the compatibility check reads.
  ;;
  ;; The record's first four fields are exactly (id start priority
  ;; kind), which is what (aud mix) reads, so the same vector goes
  ;; straight to voice-evict.  Building a second, narrower vector to
  ;; hand over would be a second description of one voice.
  (define $audio-cap #f)                ; #f = no pooling
  (define $audio-reserve 0)
  (define $audio-fade 0.005)            ; seconds; the anti-click ramp
  (define $audio-voices '())
  (define $audio-next-id 0)

  ;; cap, the loop reserve, and how long an evicted voice takes to
  ;; fade.  Every one of them is refused by name rather than clamped.
  (define (audio-voices! cap . opt)
    (let ((k (if (pair? opt) (car opt) 0))
          (fade (if (and (pair? opt) (pair? (cdr opt))) (cadr opt) 0.005)))
      (unless (and (integer? cap) (exact? cap) (> cap 0))
        (error 'audio-voices! "the cap must be a positive exact integer" cap))
      (unless (and (integer? k) (exact? k) (>= k 0))
        (error 'audio-voices! "the loop reserve must be a non-negative exact integer" k))
      (unless (< k cap)
        (error 'audio-voices! "the cap must exceed the loop reserve" cap k))
      (let ((f (if (flonum? fade) fade (exact->inexact fade))))
        (unless (fl<? 0.0 f)
          (error 'audio-voices! "the fade must be positive" fade))
        (set! $audio-cap cap)
        (set! $audio-reserve k)
        (set! $audio-fade f)
        ;; lowering the cap under what is already playing takes effect
        ;; now, with the same policy and the same fade -- not "from the
        ;; next sound on", which is how a caller would discover it
        ($pool-shrink!))))

  (define (audio-voice-count) (length $audio-voices))

  (define ($pool-vector)
    (let* ((n (length $audio-voices))
           (v (make-vector n #f)))
      (let loop ((i 0) (vs $audio-voices))
        (if (null? vs) v
            (begin (vector-set! v i (car vs)) (loop (+ i 1) (cdr vs)))))))

  (define ($pool-find id)
    (let loop ((vs $audio-voices))
      (cond ((null? vs) #f)
            ((eq? (vector-ref (car vs) 0) id) (car vs))
            (else (loop (cdr vs))))))

  (define ($pool-drop! v)
    (let loop ((vs $audio-voices) (acc '()))
      (cond ((null? vs) (set! $audio-voices (reverse acc)))
            ((eq? (car vs) v) (loop (cdr vs) acc))
            (else (loop (cdr vs) (cons (car vs) acc))))))

  (define ($pool-shrink!)
    (when $audio-cap
      (let loop ()
        (when (> (length $audio-voices) $audio-cap)
          (let ((id (voice-weakest ($pool-vector))))
            (if id
                (begin ($voice-fade-out! ($pool-find id)) (loop))
                ;; nothing left to drop: stop rather than spin
                #f))))))

  ;; Fade to nothing, then stop.  The disconnect is NOT done here: it
  ;; happens in the ended handler, which the browser fires when the
  ;; source actually stops -- at the END of the ramp.  Tearing the
  ;; nodes down at eviction time would cut the ramp off and bring back
  ;; the click the ramp exists to prevent.
  (define ($voice-fade-out! v)
    (when v
      (let* ((ctx ($audio-ctx!))
             (t (js->number (js-get ctx "currentTime")))
             (g (js-get (vector-ref v 6) "gain"))
             (end (+ t $audio-fade)))
        (js-method g "setValueAtTime" (js->number (js-get g "value")) t)
        (js-method g "linearRampToValueAtTime" 0.0001 end)
        (js-method (vector-ref v 4) "stop" end))))

  ;; The one place a voice's nodes are released.  All three ways a
  ;; voice can end -- it finished, stop-sound! was called, it was
  ;; evicted -- arrive here, because every one of them ends with the
  ;; source stopping and the host firing ended.  One exit, so there is
  ;; no path that forgets to disconnect.
  (define ($voice-release! v)
    (when v
      (for-each (lambda (n) (js-method n "disconnect")) (vector-ref v 5))
      ($pool-drop! v)))

  ;; Where a voice connects.  With nothing enabled this is the
  ;; destination itself, so the graph a plain (play! buf) builds is the
  ;; one it has always built -- not "the same shape plus a node whose
  ;; gain is 1".  A node inserted at unity changes no sample and every
  ;; graph, which is why the compatibility check reads the graph.
  (define $audio-bus #f)

  (define ($audio-out)
    (or $audio-bus (js-get ($audio-ctx!) "destination")))

  ;; Two gains and a merger, wired by INDEX.  Connecting both gains
  ;; straight at the destination does not pan: they sum, and hard left
  ;; comes out identical to centre (measured: 0.707107 in both channels
  ;; either way).  The merger's inputs are what separate them, so the
  ;; output and input indices are given explicitly rather than left to
  ;; a default -- "connected to the merger" and "connected to the
  ;; merger's input 0" are the same line in a log that records only the
  ;; target.
  (define ($audio-pan-chain ctx src pan)
    (let* ((gains (pan-gains pan))
           (gl (js-method ctx "createGain"))
           (gr (js-method ctx "createGain"))
           (merger (js-method ctx "createChannelMerger" 2)))
      (js-set! (js-get gl "gain") "value" (car gains))
      (js-set! (js-get gr "gain") "value" (cdr gains))
      (js-method src "connect" gl)
      (js-method src "connect" gr)
      (js-method gl "connect" merger 0 0)
      (js-method gr "connect" merger 0 1)
      merger))

  ;; Ask the pool whether this sound may start, and make room if it
  ;; may.  Answers #t to go ahead, #f to drop the request.
  ;;
  ;; voice-evict is asked BEFORE the voice exists: the candidate is not
  ;; in the pool, which is what its contract says.  'reject and
  ;; 'reserved both mean "do not start", and they stay apart all the
  ;; way out to the caller's log -- one says the sound was not
  ;; important enough, the other says the loops are holding the room.
  (define ($pool-admit! priority kind)
    (if (not $audio-cap)
        #t
        (let ((answer (voice-evict ($pool-vector) $audio-cap $audio-reserve
                                   priority kind)))
          (cond ((eq? answer #f) #t)
                ((eq? answer 'reject) #f)
                ((eq? answer 'reserved) #f)
                (else ($voice-fade-out! ($pool-find answer)) #t)))))

  (define ($audio-source buf vol rate loop? pan priority kind)
    (let* ((ctx ($audio-ctx!))
           (src (js-method ctx "createBufferSource"))
           (g (js-method ctx "createGain")))
      ;; A merger input is taken as mono, so a stereo buffer would be
      ;; folded to (L+R)/2 -- and anti-phase material would cancel to
      ;; exact silence (measured).  Refusing by name is reversible;
      ;; a silent downmix destroys what it touched.  Without a pan the
      ;; buffer never meets a merger, so it plays as it always did.
      (when (and pan (< 1 (js->number (js-get buf "numberOfChannels"))))
        (error 'play!
               "a pan needs a mono buffer: a merger folds a stereo one to mono, and anti-phase content cancels"
               (js->number (js-get buf "numberOfChannels"))))
      (if (not ($pool-admit! priority kind))
          #f                            ; refused a slot; nothing starts
          (begin
            (js-set! src "buffer" buf)
            (js-set! (js-get src "playbackRate") "value" rate)
            (when loop? (js-set! src "loop" #t))
            (js-set! (js-get g "gain") "value" vol)
            (js-method src "connect" g)
            (let* ((panned (if pan ($audio-pan-chain ctx g pan) g))
                   ;; the fade gain exists only while the pool does
                   (tail (if $audio-cap
                             (let ((fg (js-method ctx "createGain")))
                               (js-set! (js-get fg "gain") "value" 1.0)
                               (js-method panned "connect" fg)
                               fg)
                             panned)))
              (js-method tail "connect" ($audio-out))
              (when $audio-cap
                (let ((v (vector $audio-next-id
                                 (js->number (js-get ctx "currentTime"))
                                 priority kind src
                                 ;; every node this voice owns, for the
                                 ;; one release path
                                 (if (eq? panned g)
                                     (list src g tail)
                                     (list src g panned tail))
                                 tail)))
                  (set! $audio-next-id (+ $audio-next-id 1))
                  (set! $audio-voices (cons v $audio-voices))
                  (js-set! src "onended"
                           (lambda (e) ($voice-release! v) (js-undefined)))))
              (js-method src "start" 0)
              src)))))

  ;; (play! buf [volume [rate [pan]]]).  Leaving pan out is not the
  ;; same as passing 0: absent means the old chain, untouched, while an
  ;; explicit 0 is a centred pan and pays the equal-power 0.707 like
  ;; every other angle.  Absence and zero are different questions, and
  ;; making 0 mean "skip it" would put a 3 dB step between pan 0 and
  ;; pan 0.0001.
  (define (play! buf . opt)
    ($audio-source buf
                   (if (null? opt) 1.0 (car opt))
                   (if (or (null? opt) (null? (cdr opt))) 1.0 (cadr opt))
                   #f
                   (if (or (null? opt) (null? (cdr opt)) (null? (cddr opt)))
                       #f
                       (caddr opt))
                   ;; a middle priority: an effect competes with other
                   ;; effects and loses to music
                   (if (or (null? opt) (null? (cdr opt)) (null? (cddr opt))
                           (null? (cdddr opt)))
                       1.0
                       (cadddr opt))
                   'sfx))

  ;; Music takes a reserved slot and outranks effects by default, so a
  ;; fight does not silence the score.
  (define (loop-sound! buf . opt)       ; (loop-sound! buf [volume])
    ($audio-source buf (if (null? opt) 1.0 (car opt)) 1.0 #t #f 1000.0 'loop))

  (define (stop-sound! src)
    (js-method src "stop" 0)))
