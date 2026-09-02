;; 2D sprites and GL text over (gfx fx) and (web typeset).
;;
;; A glyph atlas rasterizes each distinct code point once (hidden 2d
;; canvas, measureText + fillText), uploads as one texture, and its
;; measurer doubles as the `measure` for typeset's prepare -- layout
;; and rendering share one width source, so they agree exactly:
;;
;;   (fx-init! canvas)
;;   (define at (make-atlas "20px system-ui" 20))
;;   (define bt (make-batch at))
;;   (define lay (layout (prepare "SCORE 42" (atlas-measurer at))
;;                       800.0 (atlas-line-height at)))
;;   ... per frame:
;;   (batch-begin! bt)
;;   (rect! bt 10.0 550.0 120.0 16.0  0.2 0.6 1.0 1.0)   ; a paddle
;;   (draw-text! bt lay 10.0 10.0  1.0 1.0 1.0 1.0)
;;   (batch-draw! bt)                                     ; one draw call
;;
;; The batch writes interleaved (x y | u v | r g b a) f32 quads into
;; fx-alloc'd staging memory; batch-draw! is one buffer upload and one
;; TRIANGLES draw.  Coordinates are pixels, top-left origin.  UVs are
;; atlas PIXELS -- the shader divides by u_texsize, so atlas growth
;; (2x, old face copied over) never invalidates written vertices.
;; A 2x2 white block at the atlas origin backs rect!: solid fills are
;; just tinted sprites, one program for everything.
;;
;; The glyph fragment is an alpha mask (tint rgb, tint a * texel a):
;; exact for text and solid rects, which is all the atlas holds.
;; Image sprites ride a separate path: load-image! -> make-sheet
;; uploads the pixels premultiplied, and a sheet-batch draws source
;; rectangles from it under 'premul blending -- so sprite sheets and
;; the glyph atlas each get the compositing they need.
;;
;; Glyphs wider than the atlas face are not handled; growth doubles
;; toward the GPU's MAX_TEXTURE_SIZE (typically >= 4096) and stops
;; making sense there (~28k Latin glyphs at 16px first).
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx sprite)
  (export atlas? make-atlas atlas-measurer atlas-line-height
          batch? make-batch batch-atlas
          batch-begin! sprite! rect! draw-text! batch-draw!
          load-image! sheet? make-sheet sheet-width sheet-height
          sheet-batch? make-sheet-batch sheet-batch-sheet
          sheet! sheet-draw!)
  (import (rnrs) (web js) (gfx gl) (gfx glsl) (gfx fx) (web typeset))

  (define ($spr-fl v) (if (flonum? v) v (exact->inexact v)))
  (define ($spr-ceil f)                 ; flonum -> fixnum, rounded up
    (let ((t (%fl->fx (fltruncate f))))
      (if (fl<? (fixnum->flonum t) f) (+ t 1) t)))

  ;; ---- the one program: pixel-space quads, alpha-mask texturing ----
  (define $sprite-vs
    '((attribute vec2 a_pos)            ; pixels, top-left origin
      (attribute vec2 a_uv)             ; atlas pixels
      (attribute vec4 a_tint)
      (uniform vec2 u_resolution)
      (uniform vec2 u_texsize)
      (varying vec2 v_uv)
      (varying vec4 v_tint)
      (define (main) void
        (local vec2 c (- (* (/ a_pos u_resolution) (fl 2))
                         (vec2 (fl 1) (fl 1))))
        (set! gl_Position (vec4 c.x (- c.y) (fl 0) (fl 1)))
        (set! v_uv (/ a_uv u_texsize))
        (set! v_tint a_tint))))
  (define $sprite-fs
    '((precision mediump float)
      (uniform sampler2D u_tex)
      (varying vec2 v_uv)
      (varying vec4 v_tint)
      (define (main) void
        (local vec4 t (texture2D u_tex v_uv))
        (set! gl_FragColor (vec4 v_tint.rgb (* v_tint.a t.a))))))

  ;; ---- the glyph atlas ----
  (define-record-type (atlas $make-atlas atlas?)
    (fields (mutable canvas $atlas-canvas $atlas-canvas!)
            (mutable ctx $atlas-ctx $atlas-ctx!)
            (mutable cx $atlas-cx $atlas-cx!)     ; row cursor, pixels
            (mutable cy $atlas-cy $atlas-cy!)
            (mutable dim $atlas-dim $atlas-dim!)  ; square face size
            (mutable dirty $atlas-dirty $atlas-dirty!)
            (immutable font $atlas-font)
            (immutable size $atlas-size)
            (immutable cell-h atlas-line-height)  ; row height, ~1.4x size
            (immutable tslot $atlas-tslot)
            (immutable entries $atlas-entries)))  ; cp -> #(gx gy gw gh adv)

  ;; 2d state does not survive a canvas swap; reapplied after growth
  (define ($atlas-ctx-setup! ctx font)
    (js-set! ctx "font" font)
    (js-set! ctx "textBaseline" "top")
    (js-set! ctx "fillStyle" "#fff"))

  (define (make-atlas font size . dim*) ; needs fx-init! first
    (let* ((dim (if (null? dim*) 256 (car dim*)))
           (doc (js-get (js-global) "document"))
           (cv (js-method doc "createElement" "canvas"))
           (tslot (fx-texture!)))
      (js-set! cv "width" dim)
      (js-set! cv "height" dim)
      (let ((ctx (js-method cv "getContext" "2d")))
        ($atlas-ctx-setup! ctx font)
        (js-method ctx "fillRect" 0 0 2 2)  ; the white block for rect!
        ($make-atlas cv ctx 4 0 dim #t font size
                     (+ size (quotient (* 2 size) 5) 2)
                     tslot (make-eq-hashtable)))))

  (define ($atlas-grow! at)             ; 2x face, old pixels copied
    (let* ((doc (js-get (js-global) "document"))
           (nd (* 2 ($atlas-dim at)))
           (cv (js-method doc "createElement" "canvas")))
      (js-set! cv "width" nd)
      (js-set! cv "height" nd)
      (let ((ctx (js-method cv "getContext" "2d")))
        (js-method ctx "drawImage" ($atlas-canvas at) 0 0)
        ($atlas-ctx-setup! ctx ($atlas-font at))
        ($atlas-canvas! at cv)
        ($atlas-ctx! at ctx)
        ($atlas-dim! at nd)
        ($atlas-dirty! at #t))))

  ;; rasterize cp on first sight; str is its one-code-point string
  (define ($atlas-ensure! at cp str)
    (or (hashtable-ref ($atlas-entries at) cp #f)
        (let* ((ctx ($atlas-ctx at))
               (adv ($spr-fl (js->number
                              (js-get (js-method ctx "measureText" str)
                                      "width"))))
               (w (+ ($spr-ceil adv) 2))
               (ch (atlas-line-height at)))
          (when (> (+ ($atlas-cx at) w) ($atlas-dim at))
            ($atlas-cx! at 0)
            ($atlas-cy! at (+ ($atlas-cy at) ch)))
          (let grow ()
            (when (> (+ ($atlas-cy at) ch) ($atlas-dim at))
              ($atlas-grow! at)
              (grow)))
          (let* ((cx ($atlas-cx at))
                 (cy ($atlas-cy at))
                 (e (vector (fixnum->flonum (+ cx 1))
                            (fixnum->flonum (+ cy 1))
                            (fixnum->flonum (- w 2))
                            (fixnum->flonum (- ch 2))
                            adv)))
            (js-method ($atlas-ctx at) "fillText" str (+ cx 1) (+ cy 1))
            ($atlas-cx! at (+ cx w))
            ($atlas-dirty! at #t)
            (hashtable-set! ($atlas-entries at) cp e)
            e))))

  ;; the measure for typeset's prepare: measuring IS rasterizing, so
  ;; a prepared text is already fully in the atlas when it draws
  (define (atlas-measurer at)
    (lambda (s)
      (vector-ref ($atlas-ensure!
                   at (string-fold-cp (lambda (a cp st n) cp) 0 s) s)
                  4)))

  ;; ---- the quad batch ----
  (define-record-type (batch $make-batch batch?)
    (fields (immutable atlas batch-atlas)
            (immutable prog $batch-prog)
            (immutable buf $batch-buf)
            (immutable base $batch-base)
            (immutable cap $batch-cap)  ; quads
            (mutable n $batch-n $batch-n!)))

  (define (make-batch at . cap*)        ; 192 bytes per quad
    (let* ((cap (if (null? cap*) 1024 (car cap*)))
           (prog (fx-program! $sprite-vs $sprite-fs))
           (buf (fx-buffer!)))
      ($make-batch at prog buf (fx-alloc! (* cap 192)) cap 0)))

  (define (batch-begin! bt) ($batch-n! bt 0))

  (define ($spr-v! p x y u v r g b a)   ; one vertex, 32 bytes
    (%mem-f32-set! p x)         (%mem-f32-set! (+ p 4) y)
    (%mem-f32-set! (+ p 8) u)   (%mem-f32-set! (+ p 12) v)
    (%mem-f32-set! (+ p 16) r)  (%mem-f32-set! (+ p 20) g)
    (%mem-f32-set! (+ p 24) b)  (%mem-f32-set! (+ p 28) a))

  ;; six interleaved vertices for one quad at slot n
  (define ($spr-quad! base n x y w h u v uw vh r g b a)
    (let* ((p (+ base (* n 192)))
           (x0 ($spr-fl x)) (y0 ($spr-fl y))
           (x1 (fl+ x0 ($spr-fl w))) (y1 (fl+ y0 ($spr-fl h)))
           (u0 ($spr-fl u)) (v0 ($spr-fl v))
           (u1 (fl+ u0 ($spr-fl uw))) (v1 (fl+ v0 ($spr-fl vh)))
           (r ($spr-fl r)) (g ($spr-fl g))
           (b ($spr-fl b)) (a ($spr-fl a)))
      ($spr-v! p x0 y0 u0 v0 r g b a)
      ($spr-v! (+ p 32) x1 y0 u1 v0 r g b a)
      ($spr-v! (+ p 64) x0 y1 u0 v1 r g b a)
      ($spr-v! (+ p 96) x1 y0 u1 v0 r g b a)
      ($spr-v! (+ p 128) x1 y1 u1 v1 r g b a)
      ($spr-v! (+ p 160) x0 y1 u0 v1 r g b a)))

  ;; a textured quad: pixel rect (x y w h), atlas-pixel rect (u v uw vh)
  (define (sprite! bt x y w h u v uw vh r g b a)
    (let ((n ($batch-n bt)))
      (when (>= n ($batch-cap bt))
        (error 'sprite! "batch capacity exceeded" ($batch-cap bt)))
      ($spr-quad! ($batch-base bt) n x y w h u v uw vh r g b a)
      ($batch-n! bt (+ n 1))))

  ;; a solid rectangle: sample the white block's center
  (define (rect! bt x y w h r g b a)
    (sprite! bt x y w h 1.0 1.0 0.0 0.0 r g b a))

  ;; draw a typeset layout; pass the SAME atlas's measurer to prepare
  ;; and (atlas-line-height at) as layout's line-height
  (define (draw-text! bt lay x y r g b a)
    (let ((at (batch-atlas bt)))
      (for-each
       (lambda (ln)
         (let ((ly (fl+ ($spr-fl y) ($spr-fl (line-y ln))))
               (txt (line-text ln)))
           (string-fold-cp
            (lambda (pen cp st n)
              (let ((e (or (hashtable-ref ($atlas-entries at) cp #f)
                           ($atlas-ensure! at cp
                                           (substring txt st (+ st n))))))
                (unless (or (= cp 32) (= cp 9))   ; spaces advance only
                  (sprite! bt pen ly (vector-ref e 2) (vector-ref e 3)
                           (vector-ref e 0) (vector-ref e 1)
                           (vector-ref e 2) (vector-ref e 3)
                           r g b a))
                (fl+ pen (vector-ref e 4))))
            ($spr-fl x) txt)))
       (layout-lines lay))))

  ;; ---- image sprites: a sheet is a premultiplied texture ----
  ;; the fragment multiplies the premultiplied texel by the tint;
  ;; sheet-draw! selects (cmd-blend! 'premul) to match
  (define $sheet-fs
    '((precision mediump float)
      (uniform sampler2D u_tex)
      (varying vec2 v_uv)
      (varying vec4 v_tint)
      (define (main) void
        (set! gl_FragColor (* (texture2D u_tex v_uv) v_tint)))))

  ;; (load-image! "sprites.png" (lambda (img) ...)): k runs when the
  ;; browser has the pixels; feed the img to make-sheet there
  (define (load-image! url k)
    (let ((img (js-new (js-get (js-global) "Image"))))
      (js-set! img "onload" (lambda _ (k img) (js-undefined)))
      (js-set! img "src" url)
      img))

  (define-record-type (sheet $make-sheet sheet?)
    (fields (immutable tslot $sheet-tslot)
            (immutable w sheet-width)
            (immutable h sheet-height)))

  (define (make-sheet img)              ; a loaded Image or a canvas
    (let ((tslot (fx-texture!)))
      (gl-texture-upload! tslot img #t)
      ($make-sheet tslot
                   (js->number (js-get img "width"))
                   (js->number (js-get img "height")))))

  (define-record-type (sheet-batch $make-sbatch sheet-batch?)
    (fields (immutable sheet sheet-batch-sheet)
            (immutable prog $sbatch-prog)
            (immutable buf $sbatch-buf)
            (immutable base $sbatch-base)
            (immutable cap $sbatch-cap)
            (mutable n $sbatch-n $sbatch-n!)))

  (define (make-sheet-batch sh . cap*)
    (let* ((cap (if (null? cap*) 256 (car cap*)))
           (prog (fx-program! $sprite-vs $sheet-fs))
           (buf (fx-buffer!)))
      ($make-sbatch sh prog buf (fx-alloc! (* cap 192)) cap 0)))

  ;; dest pixel rect (x y w h) from source pixel rect (sx sy sw sh)
  (define (sheet! sb x y w h sx sy sw sh r g b a)
    (let ((n ($sbatch-n sb)))
      (when (>= n ($sbatch-cap sb))
        (error 'sheet! "batch capacity exceeded" ($sbatch-cap sb)))
      ($spr-quad! ($sbatch-base sb) n x y w h sx sy sw sh r g b a)
      ($sbatch-n! sb (+ n 1))))

  (define (sheet-draw! sb)
    (let ((n ($sbatch-n sb))
          (sh (sheet-batch-sheet sb)))
      (unless (= n 0)
        (cmd-blend! 'premul)
        (fx-use! ($sbatch-prog sb) ($sbatch-buf sb))
        (cmd-buffer-data! ($sbatch-base sb) (* n 192))
        (cmd-bind-texture! 0 ($sheet-tslot sh))
        (fx-uniform! ($sbatch-prog sb) 'u_tex 0)
        (fx-uniform! ($sbatch-prog sb) 'u_resolution (fx-width) (fx-height))
        (fx-uniform! ($sbatch-prog sb) 'u_texsize
                     (sheet-width sh) (sheet-height sh))
        (cmd-draw-arrays! GL-TRIANGLES 0 (* 6 n))
        ($sbatch-n! sb 0))))

  ;; one texture refresh (if the atlas grew or gained glyphs), one
  ;; buffer upload, one draw
  (define (batch-draw! bt)
    (let ((n ($batch-n bt)) (at (batch-atlas bt)))
      (unless (= n 0)
        (when ($atlas-dirty at)
          (gl-texture-upload! ($atlas-tslot at) ($atlas-canvas at))
          ($atlas-dirty! at #f))
        (cmd-blend! 'alpha)
        (fx-use! ($batch-prog bt) ($batch-buf bt))
        (cmd-buffer-data! ($batch-base bt) (* n 192))
        (cmd-bind-texture! 0 ($atlas-tslot at))
        (fx-uniform! ($batch-prog bt) 'u_tex 0)
        (fx-uniform! ($batch-prog bt) 'u_resolution (fx-width) (fx-height))
        (fx-uniform! ($batch-prog bt) 'u_texsize
                     ($atlas-dim at) ($atlas-dim at))
        (cmd-draw-arrays! GL-TRIANGLES 0 (* 6 n))
        ($batch-n! bt 0)))))
