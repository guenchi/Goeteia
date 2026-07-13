;; expect: #t
;; (web mesh): parametric geometry, pure and fully verifiable --
;; counts, unit normals, radii, index ranges, and the staging-memory
;; writer's exact words.
(import (rnrs) (web mat) (web glsl) (web mesh))

(define (near? a b)
  (and (fl<? (fl- a b) 0.00001) (fl<? (fl- b a) 0.00001)))

(define (vert m v)                       ; (x y z nx ny nz) of vertex v
  (let ((vs (mesh-verts m)) (b (* v 6)))
    (list (vector-ref vs b) (vector-ref vs (+ b 1)) (vector-ref vs (+ b 2))
          (vector-ref vs (+ b 3)) (vector-ref vs (+ b 4))
          (vector-ref vs (+ b 5)))))

(define (all-verts? m pred)
  (let loop ((v 0))
    (or (= v (mesh-vert-count m))
        (and (apply pred (vert m v)) (loop (+ v 1))))))

(define (unit-normals? m)
  (all-verts? m (lambda (x y z nx ny nz)
                  (near? (fl+ (fl+ (fl* nx nx) (fl* ny ny)) (fl* nz nz))
                         1.0))))

(define (indices-in-range? m)
  (let ((ix (mesh-indices m)) (n (mesh-vert-count m)))
    (let loop ((i 0))
      (or (= i (vector-length ix))
          (and (< (vector-ref ix i) n) (loop (+ i 1)))))))

(define plane (mesh-plane 4.0 2.0))
(define box (mesh-box 2 2 2))
(define sphere (mesh-sphere 2.0 8 4))
(define cyl (mesh-cylinder 1.0 2.0 8))
(define torus (mesh-torus 2.0 0.5 8 6))

(and
 ;; plane: one quad on xz, +y normals, the right extents
 (= (mesh-vert-count plane) 4)
 (= (mesh-index-count plane) 6)
 (all-verts? plane (lambda (x y z nx ny nz)
                     (and (near? ny 1.0) (near? nx 0.0) (near? nz 0.0)
                          (near? (fl* x x) 4.0) (near? (fl* z z) 1.0))))
 ;; box 2x2x2 = the unit cube: 24 verts, 576/72 staging bytes
 (= (mesh-vert-count box) 24)
 (= (mesh-index-count box) 36)
 (= (mesh-vertex-bytes box) 576)
 (= (mesh-index-bytes box) 72)
 (unit-normals? box)
 ;; the first face is +x: position x = 1, normal (1 0 0)
 (let ((v (vert box 0)))
   (and (near? (list-ref v 0) 1.0)
        (near? (list-ref v 3) 1.0)
        (near? (list-ref v 4) 0.0)))
 ;; sphere: (segs+1)(rings+1) grid, |pos| = r, normal = pos / r
 (= (mesh-vert-count sphere) 45)
 (= (mesh-index-count sphere) (* 8 4 6))
 (unit-normals? sphere)
 (all-verts? sphere
             (lambda (x y z nx ny nz)
               (and (near? (fl+ (fl+ (fl* x x) (fl* y y)) (fl* z z)) 4.0)
                    (near? x (fl* 2.0 nx))
                    (near? y (fl* 2.0 ny))
                    (near? z (fl* 2.0 nz)))))
 ;; the first vertex is the +y pole
 (let ((v (vert sphere 0)))
   (and (near? (list-ref v 1) 2.0) (near? (list-ref v 4) 1.0)))
 ;; cylinder: side rings + capped ends
 (= (mesh-vert-count cyl) 38)                ; 2*9 side + 2*10 caps
 (= (mesh-index-count cyl) 96)
 (unit-normals? cyl)
 ;; a side vertex: radial normal, no y component
 (let ((v (vert cyl 0)))
   (and (near? (list-ref v 0) 1.0) (near? (list-ref v 1) 1.0)
        (near? (list-ref v 3) 1.0) (near? (list-ref v 4) 0.0)))
 ;; torus: every vertex sits tube-radius from the ring circle
 (= (mesh-vert-count torus) (* 9 7))
 (= (mesh-index-count torus) (* 8 6 6))
 (unit-normals? torus)
 (all-verts? torus
             (lambda (x y z nx ny nz)
               (let* ((d (flsqrt (fl+ (fl* x x) (fl* z z))))
                      (dx (fl- d 2.0)))
                 (near? (fl+ (fl* dx dx) (fl* y y)) 0.25))))
 ;; every index addresses a real vertex
 (indices-in-range? plane)
 (indices-in-range? box)
 (indices-in-range? sphere)
 (indices-in-range? cyl)
 (indices-in-range? torus)
 ;; the writer: exact f32s and packed u16 pairs in staging memory
 (begin
   (mesh-write! plane 4096 4192)
   (and (near? (%mem-f32-ref 4096) -2.0)     ; x of vertex 0
        (near? (%mem-f32-ref 4100) 0.0)
        (near? (%mem-f32-ref 4104) -1.0)
        (near? (%mem-f32-ref 4112) 1.0)      ; ny of vertex 0
        (= (%mem-i32-ref 4192) (+ 0 (* 65536 1)))
        (= (%mem-i32-ref 4196) (+ 2 (* 65536 0)))
        (= (%mem-i32-ref 4200) (+ 2 (* 65536 3)))))
 ;; the lit shaders are extractable data like any glsl forms
 (equal? (map car (glsl-attributes mesh-lit-vs)) '(a_pos a_normal))
 (equal? (glsl-uniforms mesh-lit-fs)
         '((u_light vec3) (u_color vec4) (u_ambient float)))
 ;; ---- texture coordinates ----
 ;; every generator carries them, two per vertex, inside [0,1]
 (let uv-ok ((ms (list plane box sphere cyl torus)))
   (or (null? ms)
       (let* ((m (car ms)) (uvs (mesh-uvs m)))
         (and (= (vector-length uvs) (* 2 (mesh-vert-count m)))
              (let loop ((i 0))
                (or (= i (vector-length uvs))
                    (and (fl<? -0.00001 (vector-ref uvs i))
                         (fl<? (vector-ref uvs i) 1.00001)
                         (loop (+ i 1)))))
              (uv-ok (cdr ms))))))
 ;; the plane spans the full tile corner to corner
 (near? (vector-ref (mesh-uvs plane) 0) 0.0)
 (near? (vector-ref (mesh-uvs plane) 4) 1.0)
 (near? (vector-ref (mesh-uvs plane) 5) 1.0)
 ;; the sphere seam: first vertex (0,0), last (1,1)
 (let ((uvs (mesh-uvs sphere)))
   (and (near? (vector-ref uvs 0) 0.0)
        (near? (vector-ref uvs (- (vector-length uvs) 2)) 1.0)
        (near? (vector-ref uvs (- (vector-length uvs) 1)) 1.0)))
 ;; the interleaved uv writer: 32 bytes per vertex
 (= (mesh-vertex-bytes-uv plane) 128)
 (begin
   (mesh-write-uv! plane 4608 4800)
   (and (near? (%mem-f32-ref 4608) -2.0)     ; x of vertex 0
        (near? (%mem-f32-ref 4620) 0.0)      ; nx
        (near? (%mem-f32-ref 4624) 1.0)      ; ny
        (near? (%mem-f32-ref 4632) 0.0)      ; u
        (near? (%mem-f32-ref 4636) 0.0)      ; v
        (near? (%mem-f32-ref (+ 4608 64)) 2.0)       ; vertex 2: x
        (near? (%mem-f32-ref (+ 4608 64 24)) 1.0)    ; its u
        (near? (%mem-f32-ref (+ 4608 64 28)) 1.0)    ; its v
        (= (%mem-i32-ref 4800) (+ 0 (* 65536 1)))))  ; indices unchanged
 ;; the textured shader pair declares the 32-byte layout
 (equal? (glsl-attributes mesh-tex-vs)
         '((a_pos vec3 3) (a_normal vec3 3) (a_uv vec2 2)))
 (equal? (glsl-uniforms mesh-tex-fs)
         '((u_light vec3) (u_color vec4) (u_ambient float)
           (u_tex sampler2D)))
 ;; ---- heightmaps ----
 ;; flat field: a grid of plane, normals all +y, uv corners
 (let ((m (mesh-heightmap 8.0 8.0 4 4 (lambda (x z) 0.0))))
   (and (= (mesh-vert-count m) 25)
        (= (mesh-index-count m) 96)
        (unit-normals? m)
        (all-verts? m (lambda (x y z nx ny nz)
                        (and (near? y 0.0) (near? ny 1.0))))
        (indices-in-range? m)
        (near? (vector-ref (mesh-uvs m) 0) 0.0)
        (near? (vector-ref (mesh-uvs m) (- (* 25 2) 1)) 1.0)))
 ;; a slope y = x: height follows, normals lean (-1,1,0)/sqrt2
 (let ((m (mesh-heightmap 4.0 4.0 2 2 (lambda (x z) x))))
   (and (all-verts? m (lambda (x y z nx ny nz)
                        (and (near? y x)
                             (near? nx (fl- 0.0 (fl/ 1.0 (flsqrt 2.0))))
                             (near? ny (fl/ 1.0 (flsqrt 2.0)))
                             (near? nz 0.0))))
        (unit-normals? m)))
 ;; past 65536 vertices the index stream switches to u32
 (let ((big (mesh-heightmap 10.0 10.0 300 300 (lambda (x z) 0.0))))
   (and (= (mesh-vert-count big) 90601)
        (mesh-index-u32? big)
        (= (mesh-index-bytes big) (* 4 (mesh-index-count big)))
        (begin
          (%mem-grow 75)                ; ~5 MB: 2.2M verts + 2.2M u32 indices
          (mesh-write! big 262144 2500000)
          ;; first triangle of the first cell: 0, cols=301, 302
          (and (= (%mem-i32-ref 2500000) 0)
               (= (%mem-i32-ref 2500004) 301)
               (= (%mem-i32-ref 2500008) 302)))))
 (not (mesh-index-u32? plane))
 ;; ---- bounding spheres ----
 (let ((b (mesh-bounds plane)))          ; 4 x 2 on xz
   (and (near? (v3-x (car b)) 0.0) (near? (v3-y (car b)) 0.0)
        (near? (v3-z (car b)) 0.0)
        (near? (cdr b) (flsqrt 5.0))))
 (let ((b (mesh-bounds box)))            ; 2 x 2 x 2
   (and (near? (v3-x (car b)) 0.0) (near? (v3-y (car b)) 0.0)
        (near? (v3-z (car b)) 0.0)
        (near? (cdr b) (flsqrt 3.0))))
 (near? (cdr (mesh-bounds sphere)) 2.0)
 ;; ---- tangents ----
 ;; the plane: u runs with +x, v with +z, normal +y, so the tangent
 ;; is +x and the handedness rebuilds the bitangent as +z
 (let ((tans (mesh-tangents plane)))
   (and (= (vector-length tans) 16)
        (near? (vector-ref tans 0) 1.0)      ; tx of vertex 0
        (near? (vector-ref tans 1) 0.0)
        (near? (vector-ref tans 2) 0.0)
        ;; cross(n,t) = (0,0,-1), so w = -1 makes the bitangent +z
        (near? (vector-ref tans 3) -1.0)))
 ;; every vertex of every mesh: unit tangent, orthogonal to the
 ;; normal, handedness exactly one either way
 (let mesh-ok ((ms (list plane box sphere cyl torus)))
   (or (null? ms)
       (let* ((m (car ms)) (tans (mesh-tangents m)) (vs (mesh-verts m)))
         (and (let loop ((v 0))
                (or (= v (mesh-vert-count m))
                    (let ((tx (vector-ref tans (* v 4)))
                          (ty (vector-ref tans (+ (* v 4) 1)))
                          (tz (vector-ref tans (+ (* v 4) 2)))
                          (w (vector-ref tans (+ (* v 4) 3)))
                          (nx (vector-ref vs (+ (* v 6) 3)))
                          (ny (vector-ref vs (+ (* v 6) 4)))
                          (nz (vector-ref vs (+ (* v 6) 5))))
                      (and (near? (fl+ (fl+ (fl* tx tx) (fl* ty ty))
                                       (fl* tz tz)) 1.0)
                           (near? (fl+ (fl+ (fl* tx nx) (fl* ty ny))
                                       (fl* tz nz)) 0.0)
                           (near? (fl* w w) 1.0)
                           (loop (+ v 1))))))
              (mesh-ok (cdr ms))))))
 ;; the interleaved tangent writer: 48 bytes per vertex
 (= (mesh-vertex-bytes-tan plane) 192)
 (begin
   (mesh-write-tan! plane 5120 5400)
   (and (near? (%mem-f32-ref 5120) -2.0)         ; x of vertex 0
        (near? (%mem-f32-ref 5136) 1.0)          ; ny
        (near? (%mem-f32-ref 5144) 0.0)          ; u
        (near? (%mem-f32-ref 5152) 1.0)          ; tx
        (near? (%mem-f32-ref 5156) 0.0)          ; ty
        (near? (fl* (%mem-f32-ref 5164) (%mem-f32-ref 5164)) 1.0) ; |w|
        (near? (%mem-f32-ref (+ 5120 96)) 2.0)   ; vertex 2: x
        (near? (%mem-f32-ref (+ 5120 96 24)) 1.0); its u
        (= (%mem-i32-ref 5400) (+ 0 (* 65536 1)))))
 ;; the normal-mapped pair declares the 48-byte layout
 (equal? (glsl-attributes mesh-normal-vs)
         '((a_pos vec3 3) (a_normal vec3 3) (a_uv vec2 2)
           (a_tangent vec4 4)))
 (equal? (glsl-uniforms mesh-normal-fs)
         '((u_nmap sampler2D) (u_light vec3) (u_color vec4)
           (u_ambient float)))
 ;; the PBR pair: 24-byte layout, the factor uniforms, the sky probe
 (equal? (glsl-attributes mesh-pbr-vs) '((a_pos vec3 3) (a_normal vec3 3)))
 (equal? (glsl-uniforms mesh-pbr-fs)
         '((u_light vec3) (u_eye vec3) (u_albedo vec4)
           (u_metallic float) (u_roughness float)
           (u_sky samplerCube)))
 ;; and it renders to source without incident
 (< 0 (string-length (glsl->string mesh-pbr-fs))))
