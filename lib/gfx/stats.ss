;; The performance HUD: frame time, FPS, draw calls and command
;; bytes, in the corner where every engine keeps them.  The command
;; buffer makes the numbers free -- draws were counted as they
;; encoded (cmd-draws) and the frame's size IS the write cursor
;; (cmd-pos), so nothing here instruments anything.
;;
;;   (define hud (make-stats))            ; after fx-init!
;;   (fx-loop! (lambda (t dt)
;;               ...the frame...
;;               (stats-draw! hud dt)))   ; LAST, so it sees it all
;;
;; One (gfx sprite) batch draws a translucent backdrop, a 60-frame
;; frame-time strip (each sliver one frame; taller is slower; the
;; 16.7ms line is where 60fps lives), and one line of text re-set
;; every quarter second.  The HUD's own commands land after the
;; numbers are read, so it never counts itself.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx stats)
  (export make-stats stats-draw!)
  (import (rnrs) (gfx gl) (gfx fx) (web typeset) (gfx sprite))

  (define-record-type ($stats $make-stats stats?)
    (fields (immutable atlas $st-atlas)
            (immutable batch $st-batch)
            (immutable ring $st-ring)     ; last 60 frame times
            (mutable idx $st-idx $st-idx!)
            (mutable cool $st-cool $st-cool!)  ; frames till re-typeset
            (mutable lay $st-lay $st-lay!)))

  (define (make-stats)
    (let ((at (make-atlas "600 13px ui-monospace, Menlo, monospace" 13)))
      ($make-stats at (make-batch at)
                   (make-vector 60 0.0166) 0 0 #f)))

  (define ($st-num v)                   ; one decimal, no printer noise
    (let* ((tenths (%fl->fx (fl+ (fl* v 10.0) 0.5)))
           (whole (quotient tenths 10))
           (frac (remainder tenths 10)))
      (string-append (number->string whole) "."
                     (number->string frac))))

  (define (stats-draw! st dt)
    ;; read the frame's numbers BEFORE adding our own commands
    (let* ((draws (cmd-draws))
           (bytes (cmd-pos))
           (ring ($st-ring st))
           (idx ($st-idx st))
           (b ($st-batch st)))
      (vector-set! ring idx (if (fl<? dt 0.0001) 0.0166 dt))
      ($st-idx! st (remainder (+ idx 1) 60))
      ;; the average over the ring drives the text
      (when (= ($st-cool st) 0)
        (let sum ((k 0) (acc 0.0))
          (if (< k 60)
              (sum (+ k 1) (fl+ acc (vector-ref ring k)))
              (let* ((avg (fl/ acc 60.0))
                     (fps (%fl->fx (fl+ (fl/ 1.0 avg) 0.5)))
                     (text (string-append
                            ($st-num (fl* avg 1000.0)) " MS  "
                            (number->string fps) " FPS  "
                            (number->string draws) " DRAWS  "
                            ($st-num (fl/ (fixnum->flonum bytes)
                                          1024.0)) " KB")))
                ($st-lay! st (layout (prepare text
                                              (atlas-measurer
                                               ($st-atlas st)))
                                     600.0
                                     (atlas-line-height
                                      ($st-atlas st))))))))
      ($st-cool! st (remainder (+ ($st-cool st) 1) 15))
      ;; the panel: backdrop, the frame-time strip, the line
      (cmd-depth! #f)
      (batch-begin! b)
      (rect! b 8.0 8.0 210.0 46.0 0.04 0.05 0.09 0.72)
      (let bar ((k 0))
        (when (< k 60)
          ;; oldest to the left; 33ms tops the strip out
          (let* ((v (vector-ref ring (remainder (+ ($st-idx st) k) 60)))
                 (ms (fl* v 1000.0))
                 (h (fl* 20.0 (fl/ (if (fl<? 33.0 ms) 33.0 ms) 33.0)))
                 (slow? (fl<? 20.0 ms)))
            (rect! b (fl+ 12.0 (fl* 3.0 (fixnum->flonum k)))
                   (fl- 48.0 h) 2.0 h
                   (if slow? 0.95 0.35) (if slow? 0.45 0.85) 0.45
                   0.9))
          (bar (+ k 1))))
      ;; the 60fps line across the strip
      (rect! b 12.0 (fl- 48.0 (fl* 20.0 (fl/ 16.7 33.0)))
             180.0 1.0 1.0 1.0 1.0 0.25)
      (when ($st-lay st)
        (draw-text! b ($st-lay st) 12.0 10.0 1.0 1.0 1.0 0.95))
      (batch-draw! b))))
