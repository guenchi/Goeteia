;; expect: #t
;; (web xr) against a mock session: the handshake resolves through
;; synchronous thenables, one fake XRFrame carries two eyes with
;; known matrices and viewports, and the frame callback sees them
;; as (web mat) m4s and viewport commands.
(import (rnrs) (web js) (web gl) (web fx) (web mat) (web xr))

(js-eval "
globalThis.__xrlog = [];
(() => {
  const log = globalThis.__xrlog;
  const push = (...a) => log.push(a.join(':'));
  const then = v => ({ then(f) { return f(v) } });
  // a permissive recording GL for the real replayer
  const gl = new Proxy({
    makeXRCompatible(){ return then(true) },
    viewport(...a){ push('viewport', a.join(',')) },
    bindFramebuffer(t, fb){ push('bindFB', fb ? fb.id : 'null') },
    clearColor(){}, clear(){}, getExtension(){ return {} }
  }, { get(t, k) {
         if (k in t) return t[k];
         if (typeof k === 'string' && /^[A-Z0-9_]+$/.test(k)) return 1;
         return () => ({}); } });
  globalThis.__mockcanvas = {
    width: 800, height: 600,
    getContext(kind){ return gl } };
  // the XR device: two eyes, translated a unit apart
  const view = (tx, vx) => ({
    projectionMatrix: new Float32Array(
      [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]),
    transform: { inverse: { matrix: new Float32Array(
      [1,0,0,0, 0,1,0,0, 0,0,1,0, tx,0,0,1]) } },
    vp: { x: vx, y: 0, width: 400, height: 600 } });
  const layerFb = { id: 'XRFB' };
  const session = {
    addEventListener(k, f){ if (k === 'end') this.onend = f },
    updateRenderState(rs){ this.renderState = rs },
    requestReferenceSpace(k){ push('refspace', k); return then({}) },
    requestAnimationFrame(cb){ this.raf = cb },
    end(){ this.onend() } };
  globalThis.XRWebGLLayer = function(s, g) {
    this.framebuffer = layerFb;
    this.getViewport = v => v.vp; };
  Object.defineProperty(globalThis, 'navigator', {
    configurable: true,
    value: { xr: {
      isSessionSupported(m){ push('probe', m); return then(true) },
      requestSession(m){ push('session', m); return then(session) } } } });
  globalThis.__xr_frame = () => {
    session.raf(1000, {
      getViewerPose(space){ return { views: [view(-1, 0),
                                            view(1, 400)] } } }); };
  globalThis.__xr_end = () => session.end();
})()")

(define log (js-get (js-global) "__xrlog"))
(define (entry i) (js->string (js-index log i)))
(define (has? s)
  (let ((n (js->number (js-get log "length"))))
    (let loop ((i 0))
      (and (< i n)
           (or (string=? (entry i) s) (loop (+ i 1)))))))

(fx-init! (js-get (js-global) "__mockcanvas"))

;; support answers synchronously through the mock's thenables
(define supported 'unset)
(xr-supported? (lambda (ok) (set! supported (js-truthy? ok))))

;; start, then hand-crank one XR frame
(define frames '())
(define ended #f)
(xr-start! (js-get (js-global) "__mockcanvas")
           (lambda (t)
             (cmd-begin!)
             (cmd-bind-target! (xr-framebuffer))
             (let eye ((i 0))
               (when (< i (xr-eye-count))
                 (xr-eye-viewport! i)
                 (eye (+ i 1))))
             (cmd-flush!)
             (set! frames (cons t frames)))
           (lambda () (set! ended #t)))
(js-eval "globalThis.__xr_frame()")

(define frame-ok
  (and (equal? frames '(1.0))
       (= (xr-eye-count) 2)
       ;; eye vp = identity proj x translated view: tx survives
       (let ((m (xr-eye-vp 0)))
         (and (fl<? (fl- (vector-ref m 12) -1.0) 0.0001)
              (fl<? (fl- -1.0 (vector-ref m 12)) 0.0001)))
       (let ((m (xr-eye-vp 1)))
         (fl<? (fl- (vector-ref m 12) 1.0) 0.0001))
       (has? "bindFB:XRFB")
       (has? "viewport:0,0,400,600")
       (has? "viewport:400,0,400,600")))

(js-eval "globalThis.__xr_end()")

(and (eq? supported #t)
     (has? "probe:immersive-vr")
     (has? "session:immersive-vr")
     (has? "refspace:local")
     frame-ok
     ended)
