;; expect: #t
;; sgl-draw! projects with the aspect of the viewport the stream set,
;; not the canvas's (R41: archive/goeteia-m27-2026-11-12.md).
;;
;; THE DEFECT.  sgl-draw! built its view-projection from the CANVAS's
;; width over height.  Drawn into an offscreen target, or into a part of
;; the canvas (a split screen), of another shape, every node's u_mvp and
;; the frame's environment block (u_vp) were stretched.  The matrix is
;; computed when the draw is encoded, so resolving at replay (R34) cannot
;; help.
;;
;; THE RULE.  The aspect is, in order: the caller's, when one is given
;; ((sgl-draw! sc aspect), a positive number); else the last viewport
;; this stream set (cmd-stream-viewport, believed under the R40 rule for
;; a value the stream sets: cmd-stamp-in-stream? of the stamp taken after
;; its words); else the canvas, as before.  fx-bind-target!,
;; fx-bind-canvas! and the frame loops set a viewport, so they are
;; followed.
;;
;; THE INSTRUMENT.  test/lib/glstate.ss: each draw's line holds the
;; uniform values the program holds (u_mvp among them); the environment
;; block is the uniform-buffer upload, logged with the hash of its bytes.
;; The references are the same scene drawn on a canvas of the expected
;; shape, through its own viewport: object names are not in the lines,
;; so draws of two attachments compare.
;;
;; Rows (base = the tree before the change):
;;   T1  a 128x32 target bound by fx-bind-target! on a 64x64 canvas draws
;;       as on a 128x32 canvas (base: as on 64x64)
;;   V1  a 32x64 viewport of the 64x64 canvas draws as on a 32x64 canvas
;;       (base: as on 64x64)
;;   S1  the viewport set before a flush in the middle of the stream is
;;       still the stream's after it (base: as T1)
;;   (the caller's aspect, rows E1-E3, is test/sgl-draw-takes-an-aspect.ss:
;;   the tree before the change refuses to compile a second argument, and
;;   this file must be read there)
;;   C1  a stream that set no viewport draws as on the canvas (green on
;;       base)
;;   D1  a viewport set in a stream that cmd-begin! dropped is not this
;;       stream's (green on base; a record trusted across streams)
;;   Z1  a viewport whose width or height is not positive is not used:
;;       the canvas (green on base; cells r2)
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx scene) (glstate))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

(define (scene)
  (sgl (camera (@ (fov 0.9) (position 0.0 1.0 6.0) (look-at 0.0 0.0 0.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (mesh (@ (geometry (box 1 1 1)) (position 0.5 0.0 0.0) (color 1.0 0.0 0.0)))))
;; what one flushed stream drew: its draw lines and its uniform-buffer
;; uploads (the environment block)
(define (ubo-uploads)
  (filter (lambda (c) (and (>= (string-length c) 17)
                           (string=? (substring c 0 17) "bufferSubData(UB,")))
          (glstate-calls)))
(define (reading thunk)
  (cmd-begin!) (thunk) (glstate-reset!) (cmd-flush!)
  (list (glstate-draws) (ubo-uploads)))
;; the reference: the scene on a w x h canvas, through its own viewport
(define (reference w h)
  (fx-init! (glstate-canvas w h))
  (let ((s (scene)))
    (reading (lambda () (cmd-viewport! 0 0 w h) (sgl-draw! s)))))

(define r128x32 (reference 128 32))
(define r32x64 (reference 32 64))
(define r64x64 (reference 64 64))
(want "setup the references differ" (and (not (equal? r128x32 r64x64)) (not (equal? r32x64 r64x64))) #t)
(want "setup the references have draws and an environment upload"
      (and (pair? (car r128x32)) (pair? (cadr r128x32))) #t)

(fx-init! (glstate-canvas 64 64))
(define s (scene))
(define t (fx-target! 128 32))

(want "T1 a 128x32 target draws as a 128x32 canvas"
      (reading (lambda () (fx-bind-target! t) (sgl-draw! s))) r128x32)
(want "V1 a 32x64 viewport draws as a 32x64 canvas"
      (reading (lambda () (cmd-viewport! 0 0 32 64) (sgl-draw! s))) r32x64)
(want "S1 the viewport holds across a flush inside the stream"
      (begin (cmd-begin!) (fx-bind-target! t) (cmd-flush!)
             (sgl-draw! s) (glstate-reset!) (cmd-flush!)
             (list (glstate-draws) (ubo-uploads)))
      r128x32)
(want "C1 no viewport in the stream: the canvas"
      (reading (lambda () (sgl-draw! s))) r64x64)
(want "D1 a viewport of a dropped stream is not believed"
      (begin (cmd-begin!) (cmd-viewport! 0 0 32 64)
             (reading (lambda () (sgl-draw! s))))
      r64x64)
(want "Z1 a viewport of width 0 is not used: the canvas"
      (reading (lambda () (cmd-viewport! 0 0 0 64) (sgl-draw! s))) r64x64)
(want "Z1 a viewport of height 0 is not used: the canvas"
      (reading (lambda () (cmd-viewport! 0 0 32 0) (sgl-draw! s))) r64x64)
(want "Z1 a viewport of negative width is not used: the canvas"
      (reading (lambda () (cmd-viewport! 0 0 -32 64) (sgl-draw! s))) r64x64)

(display (if (null? fails) #t (reverse fails)))
