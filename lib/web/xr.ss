;; WebXR over the command buffer: the glue that walks a raw-GL
;; scene into a headset.  The architecture barely moves -- the
;; pump changes (the session's requestAnimationFrame instead of the
;; window's), the matrices change source (each eye's projection and
;; view arrive from the XRPose, written straight into staging
;; memory by one JS helper), and the frame renders once per eye
;; into the session's framebuffer.  The command buffer, the fx
;; layer and every shader stay exactly as they were.
;;
;;   (xr-supported? (lambda (ok) ...))       ; show the button?
;;   ;; inside a user gesture:
;;   (xr-start! canvas
;;     (lambda (t)                           ; once per XR frame
;;       (cmd-begin!)
;;       (cmd-bind-target! (xr-framebuffer))
;;       (cmd-clear! ...)
;;       (let eye ((i 0))
;;         (when (< i (xr-eye-count))
;;           (xr-eye-viewport! i)
;;           (draw-scene! (xr-eye-vp i))     ; proj x view, ready
;;           (eye (+ i 1))))
;;       (cmd-flush!))
;;     (lambda () ...session ended...))
;;
;; xr-eye-vp hands back projection x inverse(view) as a (web mat)
;; m4, so everything downstream -- frustum culling included --
;; works untouched.  The GL context turns xrCompatible on entry;
;; the session's framebuffer lands in an fx slot once.
;;
;; The XR path needs a headset (or the WebXR emulator extension);
;; xr-supported? answers #f gracefully everywhere else, so pages
;; ship one scene with a desktop fallback loop.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web xr)
  (export xr-supported? xr-start! xr-end!
          xr-framebuffer xr-eye-count xr-eye-viewport! xr-eye-vp)
  (import (rnrs) (web js) (web gl) (web fx) (web mat))

  (define $xr-base 0)                   ; staging: eye data lands here
  (define $xr-fb -1)
  (define $xr-session #f)

  ;; per eye, 36 f32s: proj 16, inverse view 16, viewport 4
  (define $xr-stride 144)

  (define $xr-src
    (string-append
     "globalThis.__goeteia_xr = (canvas, memory) => ({"
     "  supported(cb) {"
     "    if (!navigator.xr) { cb(false); return; }"
     "    navigator.xr.isSessionSupported('immersive-vr')"
     "      .then(ok => cb(!!ok), () => cb(false)); },"
     "  start(base, frameCb, endCb) {"
     "    const gl = canvas.getContext('webgl2');"
     "    navigator.xr.requestSession('immersive-vr')"
     "      .then(session => {"
     "        this.session = session;"
     "        session.addEventListener('end', () => endCb());"
     "        return gl.makeXRCompatible().then(() => {"
     "          const layer = new XRWebGLLayer(session, gl);"
     "          session.updateRenderState({ baseLayer: layer });"
     "          this.fb = layer.framebuffer;"
     "          return session.requestReferenceSpace('local'); })"
     "          .then(space => {"
     "            const tick = (t, frame) => {"
     "              const pose = frame.getViewerPose(space);"
     "              if (pose) {"
     "                const f32 = new Float32Array(memory.buffer);"
     "                const layer = session.renderState.baseLayer;"
     "                let at = base / 4;"
     "                const n = pose.views.length;"
     "                for (const view of pose.views) {"
     "                  f32.set(view.projectionMatrix, at);"
     "                  f32.set(view.transform.inverse.matrix, at + 16);"
     "                  const vp = layer.getViewport(view);"
     "                  f32[at + 32] = vp.x; f32[at + 33] = vp.y;"
     "                  f32[at + 34] = vp.width; f32[at + 35] = vp.height;"
     "                  at += 36;"
     "                }"
     "                new Int32Array(memory.buffer)[base / 4 - 1] = n;"
     "                frameCb(t / 1000);"
     "              }"
     "              session.requestAnimationFrame(tick); };"
     "            session.requestAnimationFrame(tick); }); }); },"
     "  framebuffer() { return this.fb; },"
     "  end() { if (this.session) this.session.end(); } });"))

  (define $xr #f)
  (define ($xr! canvas)
    (unless $xr
      (js-eval $xr-src)
      (set! $xr (js-call (js-get (js-global) "__goeteia_xr")
                         (js-undefined)
                         canvas (js-get (js-global) "__goeteia_mem")))))

  (define (xr-supported? k)
    (js-eval $xr-src)
    (let ((probe (js-call (js-get (js-global) "__goeteia_xr")
                          (js-undefined)
                          (js-undefined)
                          (js-get (js-global) "__goeteia_mem"))))
      (js-method probe "supported" k)))

  ;; call from a user gesture (a click); frame-cb runs once per XR
  ;; frame with t in seconds, end-cb when the session closes
  (define (xr-start! canvas frame-cb end-cb)
    ($xr! canvas)
    ;; eye data after a 4-byte count word, 8-aligned
    (set! $xr-base (+ (fx-alloc! (+ 8 (* 2 $xr-stride))) 8))
    (js-method $xr "start" $xr-base
               ;; the timestamp crosses as a JS number: coerce here
               ;; so the callback sees a flonum of seconds
               (lambda args
                 (frame-cb (let ((t (js->number (car args))))
                             (if (flonum? t) t (exact->inexact t)))))
               end-cb)
    ;; the session's framebuffer, into a slot once it exists: the
    ;; first frame callback runs strictly after start resolved
    (set! $xr-fb (fx-slot!))
    (set! $xr-session #t))

  (define (xr-end!)
    (when $xr (js-method $xr "end")))

  ;; the slot holding the session's framebuffer -- bind it before
  ;; drawing; registered lazily on first ask, after the layer exists
  (define $xr-fb-set #f)
  (define (xr-framebuffer)
    (unless $xr-fb-set
      (gl-slot-object! $xr-fb (js-method $xr "framebuffer"))
      (set! $xr-fb-set #t))
    $xr-fb)

  (define (xr-eye-count)
    (%mem-i32-ref (- $xr-base 4)))

  (define ($xr-f32 at) (%mem-f32-ref at))

  (define ($xr-m4 at)
    (let ((m (make-vector 16 0.0)))
      (let fill ((k 0))
        (when (< k 16)
          (vector-set! m k ($xr-f32 (+ at (* k 4))))
          (fill (+ k 1))))
      m))

  ;; projection x inverse(view) for eye i, as a (web mat) m4
  (define (xr-eye-vp i)
    (let ((at (+ $xr-base (* i $xr-stride))))
      (m4-mul ($xr-m4 at) ($xr-m4 (+ at 64)))))

  (define (xr-eye-viewport! i)
    (let ((at (+ $xr-base (* i $xr-stride) 128)))
      (cmd-viewport! (%fl->fx ($xr-f32 at))
                     (%fl->fx ($xr-f32 (+ at 4)))
                     (%fl->fx ($xr-f32 (+ at 8)))
                     (%fl->fx ($xr-f32 (+ at 12)))))))
