;; expect: #t
;; (sgl-draw! sc aspect): the caller's aspect, when given, is the
;; projection's (R41: archive/goeteia-m27-2026-11-12.md).  The rest of
;; the rule -- the stream's viewport, else the canvas -- and the defect
;; are in test/sgl-draw-aspect-follows-the-viewport.ss; the instrument
;; and the references are the same as there.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: sgl-draw!
;; takes one argument there.
;;
;; Rows:
;;   E1  (sgl-draw! sc 4.0) with no viewport set draws as on a 128x32
;;       canvas
;;   E2  the caller's aspect wins over the stream's viewport
;;   E3  an aspect that is not a positive number raises, who sgl-draw!
;;   E4  an exact aspect is taken as its value: (sgl-draw! sc 4)
;;       -- also where the instance groups compare it with the aspect
;;       their cached set was culled for (two frames of a scene whose
;;       two boxes share a geometry; cells r2)
;;   E5  an aspect whose value as a flonum is not a finite positive
;;       number raises, who sgl-draw!: +inf.0, +nan.0, an exact 10^400
;;       (no finite flonum) and an exact 10^-400 (0.0 as a flonum)
;;       (cells r2: the ruling's amendment of 2026-11-12)
;;   E6  more than one aspect raises, who sgl-draw! (cells r2)
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
(define (try thunk)
  (guard (e (#t (if (error? e) (list 'raised (condition-who e)) (list 'raised))))
    (thunk) 'returned))

(define r128x32 (reference 128 32))
(define r64x64 (reference 64 64))
(want "setup the references differ" (equal? r128x32 r64x64) #f)
(want "setup the references have draws and an environment upload"
      (and (pair? (car r128x32)) (pair? (cadr r128x32))) #t)

(fx-init! (glstate-canvas 64 64))
(define s (scene))

(want "E1 the caller's aspect, no viewport set"
      (try (lambda () (reading (lambda () (sgl-draw! s 4.0)))))
      'returned)
(want "E1 draws as a 128x32 canvas"
      (guard (e (#t 'raised)) (reading (lambda () (sgl-draw! s 4.0))))
      r128x32)
(want "E2 the caller's aspect wins over the viewport"
      (guard (e (#t 'raised)) (reading (lambda () (cmd-viewport! 0 0 32 64) (sgl-draw! s 4.0))))
      r128x32)
(want "E3 a zero aspect raises" (try (lambda () (cmd-begin!) (sgl-draw! s 0.0))) '(raised sgl-draw!))
(want "E3 a symbol raises" (try (lambda () (cmd-begin!) (sgl-draw! s 'wide))) '(raised sgl-draw!))
(want "E3 a negative aspect raises" (try (lambda () (cmd-begin!) (sgl-draw! s -4.0))) '(raised sgl-draw!))
(want "E4 an exact aspect draws as its value"
      (guard (e (#t 'raised)) (reading (lambda () (sgl-draw! s 4))))
      r128x32)

;; two boxes of one geometry make an instanced group, whose cached set
;; is keyed by the camera and the aspect; two frames, so the second
;; compares the aspect with the key the first stored
(define (iscene)
  (sgl (camera (@ (fov 0.9) (position 0.0 1.0 6.0) (look-at 0.0 0.0 0.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (mesh (@ (geometry (box 1 1 1)) (position 0.5 0.0 0.0) (color 1.0 0.0 0.0)))
       (mesh (@ (geometry (box 1 1 1)) (position -1.5 0.0 0.0) (color 0.0 1.0 0.0)))))
(define (two-frames a)
  (let ((si (iscene)))
    (guard (e (#t 'raised))
      (let* ((f1 (reading (lambda () (sgl-draw! si a))))
             (f2 (reading (lambda () (sgl-draw! si a)))))
        (list f1 f2)))))
(define inexact-frames (two-frames 4.0))
(want "setup E4 the instanced scene draws"
      (and (pair? inexact-frames) (pair? (car (car inexact-frames)))) #t)
(want "E4 an exact aspect, instanced, two frames: as its value"
      (two-frames 4) inexact-frames)

;; an exact integer with no finite flonum (the prelude has no expt)
(define ten^400 (let loop ((k 0) (n 1)) (if (= k 400) n (loop (+ k 1) (* n 10)))))
(want "E5 +inf.0 raises" (try (lambda () (cmd-begin!) (sgl-draw! s +inf.0))) '(raised sgl-draw!))
(want "E5 +nan.0 raises" (try (lambda () (cmd-begin!) (sgl-draw! s +nan.0))) '(raised sgl-draw!))
(want "E5 an exact 10^400 raises"
      (try (lambda () (cmd-begin!) (sgl-draw! s ten^400))) '(raised sgl-draw!))
(want "E5 an exact 10^-400 raises"
      (try (lambda () (cmd-begin!) (sgl-draw! s (/ 1 ten^400)))) '(raised sgl-draw!))
(want "E5 a large finite aspect is accepted" (try (lambda () (cmd-begin!) (sgl-draw! s 1e300))) 'returned)
(want "E6 two aspects raise" (try (lambda () (cmd-begin!) (sgl-draw! s 4.0 1.0))) '(raised sgl-draw!))

(display (if (null? fails) #t (reverse fails)))
