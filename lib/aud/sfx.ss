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
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (aud sfx)
  (export audio-init! audio-time
          beep! load-sound! play! loop-sound! stop-sound!)
  (import (rnrs) (web js))

  (define $audio-ctx #f)

  (define ($audio-ctx!)
    (unless $audio-ctx
      (error 'audio "call audio-init! first (after a user gesture)"))
    $audio-ctx)

  (define (audio-init!)                 ; idempotent
    (unless $audio-ctx
      (set! $audio-ctx
            (js-eval
             "new (globalThis.AudioContext || globalThis.webkitAudioContext)()"))
      ;; a context created before the gesture starts suspended
      (js-method $audio-ctx "resume"))
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

  (define ($audio-source buf vol rate loop?)
    (let* ((ctx ($audio-ctx!))
           (src (js-method ctx "createBufferSource"))
           (g (js-method ctx "createGain")))
      (js-set! src "buffer" buf)
      (js-set! (js-get src "playbackRate") "value" rate)
      (when loop? (js-set! src "loop" #t))
      (js-set! (js-get g "gain") "value" vol)
      (js-method src "connect" g)
      (js-method g "connect" (js-get ctx "destination"))
      (js-method src "start" 0)
      src))

  (define (play! buf . opt)             ; (play! buf [volume [rate]])
    ($audio-source buf
                   (if (null? opt) 1.0 (car opt))
                   (if (or (null? opt) (null? (cdr opt))) 1.0 (cadr opt))
                   #f))

  (define (loop-sound! buf . opt)       ; (loop-sound! buf [volume])
    ($audio-source buf (if (null? opt) 1.0 (car opt)) 1.0 #t))

  (define (stop-sound! src)
    (js-method src "stop" 0)))
