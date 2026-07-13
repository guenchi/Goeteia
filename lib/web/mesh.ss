;; Parametric meshes for raw-GL scenes: positions, normals, indices,
;; generated in pure Scheme -- what (web three) gets from Three.js's
;; geometry classes, without the framework.
;;
;;   (define m (mesh-torus 1.5 0.5))
;;   (define vbase (fx-alloc! (mesh-vertex-bytes m)))
;;   (define ibase (fx-alloc! (mesh-index-bytes m)))
;;   (mesh-write! m vbase ibase)
;;   ... per frame:
;;   (cmd-buffer-data! vbase (mesh-vertex-bytes m))
;;   (cmd-index-data! ibase (mesh-index-bytes m))
;;   (cmd-draw-elements! GL-TRIANGLES (mesh-index-count m))
;;
;; A mesh holds interleaved (x y z nx ny nz) flonums -- 24 bytes per
;; vertex, matching mesh-lit-vs's a_pos/a_normal layout -- and u16
;; indices (so at most 65536 vertices; every generator here is far
;; below).  Generation is pure and verifies headlessly; mesh-write!
;; lays the data into the staging memory for (web gl).
;;
;; mesh-lit-vs / mesh-lit-fs are ready-made glsl forms for one
;; directional light plus an ambient floor: uniforms u_mvp, u_model
;; (rotations/translations/uniform scale only -- normals go through
;; it with w=0), u_light (unit vector TOWARD the light), u_color,
;; u_ambient.  Compose or replace them freely; they are just data.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web mesh)
  (export mesh? mesh-verts mesh-indices mesh-uvs
          mesh-vert-count mesh-index-count
          mesh-vertex-bytes mesh-index-bytes mesh-write!
          mesh-vertex-bytes-uv mesh-write-uv!
          mesh-plane mesh-box mesh-sphere mesh-cylinder mesh-torus
          mesh-lit-vs mesh-lit-fs mesh-tex-vs mesh-tex-fs)
  (import (rnrs) (web mat))

  (define $mesh-pi 3.141592653589793)
  (define $mesh-2pi 6.283185307179586)
  (define ($mesh-fl v) (if (flonum? v) v (exact->inexact v)))

  (define-record-type (mesh $make-mesh mesh?)
    (fields (immutable verts mesh-verts)      ; interleaved x y z nx ny nz
            (immutable indices mesh-indices)
            (immutable uvs mesh-uvs)))        ; u v per vertex, in [0,1]

  (define (mesh-vert-count m) (quotient (vector-length (mesh-verts m)) 6))
  (define (mesh-index-count m) (vector-length (mesh-indices m)))
  (define (mesh-vertex-bytes m) (* 4 (vector-length (mesh-verts m))))
  (define (mesh-vertex-bytes-uv m) (* 32 (mesh-vert-count m)))
  (define (mesh-index-bytes m)                ; u16 pairs, padded to words
    (* 4 (quotient (+ (mesh-index-count m) 1) 2)))

  ;; one vertex into the verts vector at slot v
  (define ($mesh-v! vs v x y z nx ny nz)
    (let ((b (* v 6)))
      (vector-set! vs b x)
      (vector-set! vs (+ b 1) y)
      (vector-set! vs (+ b 2) z)
      (vector-set! vs (+ b 3) nx)
      (vector-set! vs (+ b 4) ny)
      (vector-set! vs (+ b 5) nz)))

  (define ($mesh-uv! uvs v u vv)        ; one vertex's texture coords
    (vector-set! uvs (* v 2) u)
    (vector-set! uvs (+ (* v 2) 1) vv))

  ;; a quad (a b | a+1 b+1) as two triangles at index slot k
  (define ($mesh-quad! ix k a b)
    (vector-set! ix k a)
    (vector-set! ix (+ k 1) b)
    (vector-set! ix (+ k 2) (+ a 1))
    (vector-set! ix (+ k 3) (+ a 1))
    (vector-set! ix (+ k 4) b)
    (vector-set! ix (+ k 5) (+ b 1)))

  ;; ---- generators ----
  (define (mesh-plane w d)                    ; on xz, +y normal
    (let ((hw (fl/ ($mesh-fl w) 2.0))
          (hd (fl/ ($mesh-fl d) 2.0))
          (vs (make-vector 24 0.0)))
      ($mesh-v! vs 0 (fl- 0.0 hw) 0.0 (fl- 0.0 hd) 0.0 1.0 0.0)
      ($mesh-v! vs 1 (fl- 0.0 hw) 0.0 hd           0.0 1.0 0.0)
      ($mesh-v! vs 2 hw           0.0 hd           0.0 1.0 0.0)
      ($mesh-v! vs 3 hw           0.0 (fl- 0.0 hd) 0.0 1.0 0.0)
      ($make-mesh vs (vector 0 1 2 0 2 3)
                  (vector 0.0 0.0  0.0 1.0  1.0 1.0  1.0 0.0))))

  ;; face table: normal then four corners, in unit coordinates
  (define $mesh-box-faces
    '(((1 0 0) (( 1 -1 -1) ( 1  1 -1) ( 1  1  1) ( 1 -1  1)))
      ((-1 0 0) ((-1 -1  1) (-1  1  1) (-1  1 -1) (-1 -1 -1)))
      ((0 1 0) ((-1  1 -1) (-1  1  1) ( 1  1  1) ( 1  1 -1)))
      ((0 -1 0) ((-1 -1  1) (-1 -1 -1) ( 1 -1 -1) ( 1 -1  1)))
      ((0 0 1) ((-1 -1  1) ( 1 -1  1) ( 1  1  1) (-1  1  1)))
      ((0 0 -1) (( 1 -1 -1) (-1 -1 -1) (-1  1 -1) ( 1  1 -1)))))

  (define (mesh-box w h d)
    (let ((hx (fl/ ($mesh-fl w) 2.0))
          (hy (fl/ ($mesh-fl h) 2.0))
          (hz (fl/ ($mesh-fl d) 2.0))
          (vs (make-vector 144 0.0))          ; 24 verts
          (uvs (make-vector 48 0.0))
          (ix (make-vector 36 0)))
      (let face ((fs $mesh-box-faces) (f 0))
        (unless (null? fs)
          (let* ((spec (car fs))
                 (n (car spec)))
            (let corner ((cs (cadr spec)) (v (* f 4)))
              (unless (null? cs)
                (let ((c (car cs))
                      (k (- v (* f 4))))      ; corner 0..3 -> a full tile
                  ($mesh-v! vs v
                            (fl* hx (fixnum->flonum (car c)))
                            (fl* hy (fixnum->flonum (cadr c)))
                            (fl* hz (fixnum->flonum (caddr c)))
                            (fixnum->flonum (car n))
                            (fixnum->flonum (cadr n))
                            (fixnum->flonum (caddr n)))
                  ($mesh-uv! uvs v
                             (if (< k 2) 0.0 1.0)
                             (if (or (= k 1) (= k 2)) 1.0 0.0)))
                (corner (cdr cs) (+ v 1))))
            (let ((b (* f 4)) (k (* f 6)))
              (vector-set! ix k b)
              (vector-set! ix (+ k 1) (+ b 1))
              (vector-set! ix (+ k 2) (+ b 2))
              (vector-set! ix (+ k 3) b)
              (vector-set! ix (+ k 4) (+ b 2))
              (vector-set! ix (+ k 5) (+ b 3))))
          (face (cdr fs) (+ f 1))))
      ($make-mesh vs ix uvs)))

  (define (mesh-sphere r . opt)               ; UV sphere from the +y pole
    (let* ((segs (if (null? opt) 24 (car opt)))
           (rings (if (or (null? opt) (null? (cdr opt))) 16 (cadr opt)))
           (r ($mesh-fl r))
           (cols (+ segs 1))
           (vs (make-vector (* (+ rings 1) cols 6) 0.0))
           (uvs (make-vector (* (+ rings 1) cols 2) 0.0))
           (ix (make-vector (* rings segs 6) 0)))
      (let ring ((i 0))
        (when (<= i rings)
          (let* ((phi (fl/ (fl* $mesh-pi (fixnum->flonum i))
                           (fixnum->flonum rings)))
                 (sp (flsin phi))
                 (cp (flcos phi)))
            (let seg ((j 0))
              (when (<= j segs)
                (let* ((th (fl/ (fl* $mesh-2pi (fixnum->flonum j))
                                (fixnum->flonum segs)))
                       (nx (fl* sp (flcos th)))
                       (nz (fl* sp (flsin th))))
                  ($mesh-v! vs (+ (* i cols) j)
                            (fl* r nx) (fl* r cp) (fl* r nz)
                            nx cp nz)
                  ($mesh-uv! uvs (+ (* i cols) j)
                             (fl/ (fixnum->flonum j) (fixnum->flonum segs))
                             (fl/ (fixnum->flonum i) (fixnum->flonum rings))))
                (seg (+ j 1)))))
          (ring (+ i 1))))
      (let quad ((i 0) (k 0))
        (when (< i rings)
          (let inner ((j 0) (k k))
            (if (= j segs)
                (quad (+ i 1) k)
                (begin
                  ($mesh-quad! ix k (+ (* i cols) j) (+ (* (+ i 1) cols) j))
                  (inner (+ j 1) (+ k 6)))))))
      ($make-mesh vs ix uvs)))

  (define (mesh-cylinder r h . opt)
    (let* ((segs (if (null? opt) 24 (car opt)))
           (r ($mesh-fl r))
           (hy (fl/ ($mesh-fl h) 2.0))
           (cols (+ segs 1))
           (topc (* 2 cols))                  ; cap centers and rings
           (botc (+ topc cols 1))
           (vs (make-vector (* (+ botc cols 1) 6) 0.0))
           (uvs (make-vector (* (+ botc cols 1) 2) 0.0))
           (ix (make-vector (* 12 segs) 0)))
      (let seg ((j 0))
        (when (<= j segs)
          (let* ((th (fl/ (fl* $mesh-2pi (fixnum->flonum j))
                          (fixnum->flonum segs)))
                 (c (flcos th)) (s (flsin th))
                 (x (fl* r c)) (z (fl* r s))
                 (u (fl/ (fixnum->flonum j) (fixnum->flonum segs)))
                 (cu (fl+ 0.5 (fl* 0.5 c)))   ; caps: the disc itself
                 (cv (fl+ 0.5 (fl* 0.5 s))))
            ($mesh-v! vs j x hy z c 0.0 s)                  ; side, top ring
            ($mesh-v! vs (+ cols j) x (fl- 0.0 hy) z c 0.0 s)
            ($mesh-v! vs (+ topc 1 j) x hy z 0.0 1.0 0.0)   ; cap rings
            ($mesh-v! vs (+ botc 1 j) x (fl- 0.0 hy) z 0.0 -1.0 0.0)
            ($mesh-uv! uvs j u 0.0)
            ($mesh-uv! uvs (+ cols j) u 1.0)
            ($mesh-uv! uvs (+ topc 1 j) cu cv)
            ($mesh-uv! uvs (+ botc 1 j) cu cv))
          (seg (+ j 1))))
      ($mesh-v! vs topc 0.0 hy 0.0 0.0 1.0 0.0)
      ($mesh-v! vs botc 0.0 (fl- 0.0 hy) 0.0 0.0 -1.0 0.0)
      ($mesh-uv! uvs topc 0.5 0.5)
      ($mesh-uv! uvs botc 0.5 0.5)
      (let idx ((j 0) (k 0))
        (when (< j segs)
          ($mesh-quad! ix k j (+ cols j))
          (vector-set! ix (+ k 6) topc)
          (vector-set! ix (+ k 7) (+ topc 1 j 1))
          (vector-set! ix (+ k 8) (+ topc 1 j))
          (vector-set! ix (+ k 9) botc)
          (vector-set! ix (+ k 10) (+ botc 1 j))
          (vector-set! ix (+ k 11) (+ botc 1 j 1))
          (idx (+ j 1) (+ k 12))))
      ($make-mesh vs ix uvs)))

  (define (mesh-torus big small . opt)        ; ring radius, tube radius
    (let* ((segs (if (null? opt) 32 (car opt)))         ; around the ring
           (rings (if (or (null? opt) (null? (cdr opt))) 16 (cadr opt)))
           (br ($mesh-fl big))
           (tr ($mesh-fl small))
           (cols (+ rings 1))
           (vs (make-vector (* (+ segs 1) cols 6) 0.0))
           (uvs (make-vector (* (+ segs 1) cols 2) 0.0))
           (ix (make-vector (* segs rings 6) 0)))
      (let seg ((i 0))
        (when (<= i segs)
          (let* ((th (fl/ (fl* $mesh-2pi (fixnum->flonum i))
                          (fixnum->flonum segs)))
                 (ct (flcos th)) (st (flsin th)))
            (let tube ((j 0))
              (when (<= j rings)
                (let* ((ph (fl/ (fl* $mesh-2pi (fixnum->flonum j))
                                (fixnum->flonum rings)))
                       (cp (flcos ph)) (sp (flsin ph))
                       (d (fl+ br (fl* tr cp))))
                  ($mesh-v! vs (+ (* i cols) j)
                            (fl* d ct) (fl* tr sp) (fl* d st)
                            (fl* cp ct) sp (fl* cp st))
                  ($mesh-uv! uvs (+ (* i cols) j)
                             (fl/ (fixnum->flonum i) (fixnum->flonum segs))
                             (fl/ (fixnum->flonum j) (fixnum->flonum rings))))
                (tube (+ j 1)))))
          (seg (+ i 1))))
      (let quad ((i 0) (k 0))
        (when (< i segs)
          (let inner ((j 0) (k k))
            (if (= j rings)
                (quad (+ i 1) k)
                (begin
                  ($mesh-quad! ix k (+ (* i cols) j) (+ (* (+ i 1) cols) j))
                  (inner (+ j 1) (+ k 6)))))))
      ($make-mesh vs ix uvs)))

  ;; ---- into the staging memory: f32 verts, u16 index pairs ----
  (define ($mesh-write-ix! m ibase)
    (let* ((ix (mesh-indices m))
           (n (vector-length ix)))
      (let loop ((i 0) (at ibase))
        (when (< i n)
          (%mem-i32-set! at
                         (+ (vector-ref ix i)
                            (* 65536 (if (< (+ i 1) n)
                                         (vector-ref ix (+ i 1))
                                         0))))
          (loop (+ i 2) (+ at 4))))))

  (define (mesh-write! m vbase ibase)
    (let ((vs (mesh-verts m)))
      (let loop ((i 0) (at vbase))
        (when (< i (vector-length vs))
          (%mem-f32-set! at (vector-ref vs i))
          (loop (+ i 1) (+ at 4)))))
    ($mesh-write-ix! m ibase))

  ;; interleaved x y z nx ny nz u v -- 32 bytes per vertex, matching
  ;; mesh-tex-vs's a_pos/a_normal/a_uv layout
  (define (mesh-write-uv! m vbase ibase)
    (let ((vs (mesh-verts m))
          (uvs (mesh-uvs m))
          (n (mesh-vert-count m)))
      (let loop ((v 0) (at vbase))
        (when (< v n)
          (let ((b (* v 6)) (ub (* v 2)))
            (%mem-f32-set! at (vector-ref vs b))
            (%mem-f32-set! (+ at 4) (vector-ref vs (+ b 1)))
            (%mem-f32-set! (+ at 8) (vector-ref vs (+ b 2)))
            (%mem-f32-set! (+ at 12) (vector-ref vs (+ b 3)))
            (%mem-f32-set! (+ at 16) (vector-ref vs (+ b 4)))
            (%mem-f32-set! (+ at 20) (vector-ref vs (+ b 5)))
            (%mem-f32-set! (+ at 24) (vector-ref uvs ub))
            (%mem-f32-set! (+ at 28) (vector-ref uvs (+ ub 1))))
          (loop (+ v 1) (+ at 32)))))
    ($mesh-write-ix! m ibase))

  ;; ---- the standard lit program, as composable glsl forms ----
  (define mesh-lit-vs
    '((attribute vec3 a_pos)
      (attribute vec3 a_normal)
      (uniform mat4 u_mvp)
      (uniform mat4 u_model)
      (varying vec3 v_normal)
      (define (main) void
        (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
        (set! v_normal (vec3 (* u_model (vec4 a_normal (fl 0))))))))

  (define mesh-lit-fs
    '((precision mediump float)
      (uniform vec3 u_light)                  ; unit vector toward the light
      (uniform vec4 u_color)
      (uniform float u_ambient)
      (varying vec3 v_normal)
      (define (main) void
        (local vec3 n (normalize v_normal))
        (local float d (max (dot n u_light) (fl 0)))
        (set! gl_FragColor
              (vec4 (* u_color.rgb
                       (+ u_ambient (* d (- (fl 1) u_ambient))))
                    u_color.a)))))

  ;; the same light over a texture: sample * u_color tint, then the
  ;; ambient/diffuse factor.  Pair with mesh-write-uv! (stride 32).
  (define mesh-tex-vs
    '((attribute vec3 a_pos)
      (attribute vec3 a_normal)
      (attribute vec2 a_uv)
      (uniform mat4 u_mvp)
      (uniform mat4 u_model)
      (varying vec3 v_normal)
      (varying vec2 v_uv)
      (define (main) void
        (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
        (set! v_normal (vec3 (* u_model (vec4 a_normal (fl 0)))))
        (set! v_uv a_uv))))
  (define mesh-tex-fs
    '((precision mediump float)
      (uniform vec3 u_light)
      (uniform vec4 u_color)
      (uniform float u_ambient)
      (uniform sampler2D u_tex)
      (varying vec3 v_normal)
      (varying vec2 v_uv)
      (define (main) void
        (local vec3 n (normalize v_normal))
        (local float d (max (dot n u_light) (fl 0)))
        (local vec4 t (* (texture2D u_tex v_uv) u_color))
        (set! gl_FragColor
              (vec4 (* t.rgb (+ u_ambient (* d (- (fl 1) u_ambient))))
                    t.a))))))
