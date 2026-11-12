;; expect: #t
;; After fx-use! or fx-use-instanced!, the bound array buffer is the
;; VERTEX buffer, on every path (R55: archive/goeteia-m26-2026-11-12.md).
;;
;; THE DEFECT.  The library's own comment says a dynamic stream uploads
;; right after fx-use!, into the buffer it names.  The instanced use that
;; sets its vertex array up -- the first use, or one whose setup words
;; were dropped -- bound the instance buffer last and left it bound, so
;; an upload right after it went into the instance buffer; a later use
;; bound the vertex buffer.  The same call put the next upload in a
;; different buffer depending on what the cache held.
;;
;; THE RULE.  Every use leaves the vertex buffer bound: the setup path
;; binds it again after the instance attributes.
;;
;; Mock: test/lib/glstate.ss.  An upload goes to the bound array buffer;
;; a draw is judged by what its attributes' buffers hold.  The reference
;; is a draw whose buffers were filled with the same bytes before the use.
;;
;; Rows (base = the tree before the change):
;;   N1  the first instanced use, then an upload: the vertex attribute
;;       reads the uploaded bytes, the instance attribute its own (base:
;;       the upload replaces the instance buffer)
;;   N2  a later instanced use, the same, with ANOTHER buffer (the
;;       instance buffer) bound before it: the use binds the vertex buffer
;;       itself (green on base; a hit path that leaves the binding alone)
;;   N3  an instanced use whose setup was dropped by cmd-begin!, the same
;;       (base: as N1)
;;   C1  fx-use!, the same (green on base)
(import (rnrs) (web js) (gfx gl) (gfx fx) (glstate))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

(fx-init! (glstate-canvas 64 64))
(define (iprog)
  (fx-program! '((attribute vec2 a_pos) (attribute vec2 i_offset)
                 (define (main) void (set! gl_Position (vec4 (+ a_pos i_offset) (fl 0) (fl 1)))))
               '((precision mediump float)
                 (define (main) void (set! gl_FragColor (vec4 (fl 1) (fl 0) (fl 0) (fl 1)))))))
(define (vprog)
  (fx-program! '((attribute vec2 a_pos)
                 (define (main) void (set! gl_Position (vec4 a_pos (fl 0) (fl 1)))))
               '((precision mediump float)
                 (define (main) void (set! gl_FragColor (vec4 (fl 1) (fl 0) (fl 0) (fl 1)))))))
;; 64 staged bytes, distinct per seed
(define (staged seed)
  (let ((at (fx-alloc! 64)))
    (let fill ((i 0))
      (when (< i 16)
        (%mem-f32-set! (+ at (* 4 i)) (+ seed (* 0.5 (fixnum->flonum i))))
        (fill (+ i 1))))
    at))
(define old-v (staged 1.0))
(define new-v (staged 50.0))
(define inst (staged 100.0))
;; a buffer holding the bytes at `at`
(define (filled at)
  (let ((b (fx-buffer!)))
    (cmd-begin!) (cmd-bind-buffer! b) (cmd-buffer-data! at 64) (cmd-flush!)
    b))
(define (D) (cmd-draw-elements-instanced! GL-TRIANGLES 3 2))
(define (A) (cmd-draw-arrays! GL-TRIANGLES 0 3))
;; the draws of one flushed stream
(define (frame thunk)
  (cmd-begin!) (thunk) (glstate-reset!) (cmd-flush!) (glstate-draws))
;; the same draw, from buffers that held the uploaded bytes before the use
(define (iref)
  (let ((p (iprog)) (vb (filled new-v)) (ib (filled inst)))
    (frame (lambda () (fx-use-instanced! p vb ib) (D)))))
(define (vref)
  (let ((p (vprog)) (vb (filled new-v)))
    (frame (lambda () (fx-use! p vb) (A)))))
;; use, then upload the new vertex bytes, then draw
(define (use-upload-draw p vb ib)
  (fx-use-instanced! p vb ib) (cmd-buffer-data! new-v 64) (D))

(let* ((ref (iref)) (p (iprog)) (vb (filled old-v)) (ib (filled inst)))
  (want "N1 the first instanced use leaves the vertex buffer bound"
        (frame (lambda () (use-upload-draw p vb ib))) ref))

(let* ((ref (iref)) (p (iprog)) (vb (filled old-v)) (ib (filled inst)))
  (frame (lambda () (fx-use-instanced! p vb ib) (D)))
  (cmd-begin!) (cmd-bind-buffer! vb) (cmd-buffer-data! old-v 64)
  (cmd-bind-buffer! ib) (cmd-flush!)
  (want "N2 a later instanced use leaves the vertex buffer bound"
        (frame (lambda () (use-upload-draw p vb ib))) ref))

(let* ((ref (iref)) (p (iprog)) (vb (filled old-v)) (ib (filled inst)))
  (cmd-begin!) (fx-use-instanced! p vb ib)
  (want "N3 a use whose setup was dropped leaves the vertex buffer bound"
        (frame (lambda () (use-upload-draw p vb ib))) ref))

(let* ((ref (vref)) (p (vprog)) (vb (filled old-v)))
  (want "C1 fx-use! leaves the vertex buffer bound"
        (frame (lambda () (fx-use! p vb) (cmd-buffer-data! new-v 64) (A))) ref))

(display (if (null? fails) #t (reverse fails)))
