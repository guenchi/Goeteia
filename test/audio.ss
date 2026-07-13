;; expect: #t
;; (web audio) against a recording mock: init is idempotent, beeps
;; wire oscillator->gain->destination with a click-free fade, loads
;; run the fetch/decode chain (synchronous thenables stand in for
;; promises), and buffer playback sets volume, rate and looping.
(import (rnrs) (web js) (web audio))

(js-eval "globalThis.__alog = []; globalThis.__push = (...a) => globalThis.__alog.push(a.join(':')); globalThis.__syncThen = (v) => ({ then(f) { const r = f(v); return (r && r.then) ? r : globalThis.__syncThen(r); } }); globalThis.AudioContext = function() { const push = globalThis.__push; this.currentTime = 2.0; this.destination = { id:'DEST' }; this.resume = () => push('resume'); this.createOscillator = () => ({ id:'OSC', type:'', frequency:{ value:0 }, connect(x){ push('osc.connect', x.id) }, start(t){ push('osc.start', t.toFixed(2)) }, stop(t){ push('osc.stop', t.toFixed(2)) } }); this.createGain = () => ({ id:'GAIN', gain:{ value:0, setValueAtTime(v,t){ push('gain.set', v.toFixed(2), t.toFixed(2)) }, linearRampToValueAtTime(v,t){ push('gain.ramp', v.toFixed(4), t.toFixed(2)) } }, connect(x){ push('gain.connect', x.id) } }); this.createBufferSource = () => ({ id:'SRC', buffer:null, loop:false, playbackRate:{ value:1 }, connect(x){ push('src.connect', x.id) }, start(t){ push('src.start', t) }, stop(t){ push('src.stop', t) } }); this.decodeAudioData = (ab) => { push('decode', ab.id); return globalThis.__syncThen({ id:'BUF' }); }; }; globalThis.fetch = (url) => { globalThis.__push('fetch', url); return globalThis.__syncThen({ arrayBuffer: () => globalThis.__syncThen({ id:'AB' }) }); }")

(define alog (js-get (js-global) "__alog"))
(define (entry i) (js->string (js-index alog i)))
(define (log-len) (js->number (js-get alog "length")))
(define (prefix? p s)
  (and (<= (string-length p) (string-length s))
       (string=? p (substring s 0 (string-length p)))))
(define (count-log p)
  (let ((n (log-len)))
    (let loop ((i 0) (c 0))
      (if (= i n)
          c
          (loop (+ i 1) (if (prefix? p (entry i)) (+ c 1) c))))))
(define (check-from base es)
  (let loop ((i base) (es es))
    (or (null? es)
        (and (or (string=? (entry i) (car es))
                 (begin (display "mismatch at ") (display i)
                        (display ": got ") (display (entry i))
                        (display " want ") (display (car es)) (newline)
                        #f))
             (loop (+ i 1) (cdr es))))))

;; init is idempotent: one context, one resume
(audio-init!)
(audio-init!)
(define init-ok
  (and (= (count-log "resume") 1)
       (= (audio-time) 2.0)))

;; a beep: envelope, wiring, timed start/stop; defaults then options
(define base-b (log-len))
(define osc (beep! 440 0.5))
(define beep-ok
  (and (check-from base-b '("gain.set:0.30:2.00"
                            "gain.ramp:0.0001:2.50"
                            "osc.connect:GAIN"
                            "gain.connect:DEST"
                            "osc.start:2.00"
                            "osc.stop:2.50"))
       (string=? (js->string (js-get osc "type")) "square")
       (= (js->number (js-get (js-get osc "frequency") "value")) 440)))
(define osc2 (beep! 880 0.25 0.2 "sine"))
(define beep2-ok
  (and (string=? (js->string (js-get osc2 "type")) "sine")
       (= (js->number (js-get (js-get osc2 "frequency") "value")) 880)
       (= (count-log "gain.set:0.20") 1)))

;; load: the fetch -> arrayBuffer -> decode chain reaches k
(define got #f)
(load-sound! "hit.ogg" (lambda (buf) (set! got buf)))
(define load-ok
  (and (js-ref? got)
       (string=? (js->string (js-get got "id")) "BUF")
       (= (count-log "fetch:hit.ogg") 1)
       (= (count-log "decode:AB") 1)))

;; playback: buffer, volume path, rate; loop only when asked
(define base-p (log-len))
(define src (play! got 0.5 1.2))
(define (near-rate? v) (and (< 1.19 v) (< v 1.21)))
(define play-ok
  (and (check-from base-p '("src.connect:GAIN"
                            "gain.connect:DEST"
                            "src.start:0"))
       (string=? (js->string (js-get (js-get src "buffer") "id")) "BUF")
       (near-rate? (js->number (js-get (js-get src "playbackRate") "value")))
       (not (js-truthy? (js-get src "loop")))))

(define music (loop-sound! got 0.4))
(define loop-ok (js-truthy? (js-get music "loop")))
(stop-sound! music)
(define stop-ok (= (count-log "src.stop:0") 1))

(and init-ok beep-ok beep2-ok load-ok play-ok loop-ok stop-ok)
