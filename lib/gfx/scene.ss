;; Reactive raw-GL scenes -- sx for the third dimension.
;;
;;   (define angle (signal 0.0))
;;   (define sc
;;     (sgl (camera (@ (fov 0.9) (position 0.0 3.5 9.0)
;;                     (look-at 0.0 0.5 0.0)))
;;          (light (@ (direction 0.5 0.8 0.4) (ambient 0.25)))
;;          (mesh (@ (geometry (torus 1.6 0.55))
;;                   (position -1.8 0.6 0.0)
;;                   (rotation-y ,(signal-ref angle))
;;                   (color 0.95 0.45 0.35)))))
;;   (fx-loop! (lambda (t dt)
;;               (cmd-clear! 0.05 0.06 0.10 1.0)
;;               (signal-set! angle t)
;;               (sgl-draw! sc)))
;;
;; The template splits at expansion time, like sx: geometry
;; is built and uploaded once ((gfx mesh) generates it, the first
;; draw ships it), and each unquoted attribute becomes a hole whose
;; effect copies the signal's value into the node -- so a frame is
;; pure arithmetic over current fields, and only changed values move.
;;
;; Tags: (camera (@ (fov f) (near n) (far f) (position x y z)
;;                  (look-at x y z)))
;;       (light (@ (direction x y z) (ambient a)))
;;       (probe (@ (sky slot) (lut slot) (mips m)))  -- the (gfx ibl)
;;         pair the scene's pbr meshes reflect; slots may be unquotes,
;;         evaluated once
;;       (group (@ (position ...) (rotation-y ,sig) (scale s))
;;         child ...)  -- children (meshes or groups) inherit the
;;         parent transform; holes animate whole assemblies
;;       (lod (@ (switch d1 d2 ...)) mesh1 mesh2 ...)  -- detail
;;         levels of one thing: the eye's distance to it picks which
;;         child draws (under d1 the first, under d2 the second, ...)
;;       (mesh (@ (geometry SPEC) attrs...))
;; Geometry specs: (plane w d) (box w h d) (sphere r [segs rings])
;;       (cylinder r h [segs]) (torus R r [segs rings]), or a lone
;;       unquote yielding a (gfx mesh) mesh, injected once.
;; Mesh attributes: (position x y z) (rotation x y z) (color r g b [a])
;;       and the single-valued position-x/-y/-z rotation-* scale
;;       color-r/-g/-b/-a; holes go in single-valued attributes
;;       (and ambient, fov, near, far, metallic, roughness).
;; Materials, per mesh: the default renders mesh-lit-vs/-fs (one
;;       directional light, ambient floor, solid color);
;;       (texture slot) switches to mesh-tex-vs/-fs (geometry gains
;;       uvs, color multiplies); (metallic m) or (roughness r)
;;       switch to mesh-pbr-vs/-fs against the scene's probe.
;;
;; Every frame culls against the camera's frustum: a mesh whose
;; bounding sphere (mesh-bounds, scaled and placed by its fields)
;; falls outside contributes nothing, uniforms included.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx scene)
  (export sgl $sgl-build sgl-scene? sgl-draw!)
  (import (rnrs) (web js) (gfx gl) (gfx glsl) (gfx fx) (gfx mat)
          (gfx mesh) (web reactive))

  ;; ---- the template macro: the sx walker, attribute-only ----
  (define-syntax sgl
    (lambda (x)
      (syntax-case x ()
        ((_ . forms)
         (let ((thunks '()) (nd 0))
           (letrec
               ((unq?
                 (lambda (t)
                   (and (pair? t) (eq? (car t) 'unquote)
                        (pair? (cdr t)) (null? (cddr t)))))
                (add-thunk!
                 (lambda (e)
                   (set! thunks (cons (list 'lambda '() e) thunks))
                   (set! nd (+ nd 1))
                   (cons '$sgl-d (- nd 1))))
                (walk-attr
                 (lambda (a)
                   ;; (geometry ,m) or (rotation-y ,sig): one hole
                   (if (and (pair? (cdr a)) (unq? (cadr a)) (null? (cddr a)))
                       (list (car a) (add-thunk! (cadr (cadr a))))
                       a)))
                (walk-form
                 (lambda (f)
                   (let* ((tag (car f)) (rest (cdr f))
                          (attrs? (and (pair? rest) (pair? (car rest))
                                       (eq? (car (car rest)) '@)))
                          (attrs (if attrs?
                                     (cons '@ (map walk-attr
                                                   (cdr (car rest))))
                                     '(@)))
                          (kids (if attrs? (cdr rest) rest)))
                     ;; groups and lod containers nest
                     (if (or (eq? tag 'group) (eq? tag 'lod))
                         (cons tag (cons attrs (map walk-form kids)))
                         (if attrs? (list tag attrs) f))))))
             (let ((anno (map walk-form forms)))
               (list '$sgl-build (list 'quote anno)
                     (cons 'list (reverse thunks))))))))))

  (define ($sgl-d? t) (and (pair? t) (eq? (car t) '$sgl-d)))
  (define ($sgl-fl v) (if (flonum? v) v (exact->inexact v)))

  ;; ---- runtime state: plain flonum vectors, updated by effects ----
  (define-record-type (sgl-scene $make-sgl sgl-scene?)
    (fields (immutable prog $sgl-prog)     ; lit; #f when unused
            (immutable tprog $sgl-tprog)   ; tex; #f when unused
            (immutable pprog $sgl-pprog)   ; pbr; #f when unused
            (immutable iprog $sgl-iprog)   ; lit, instanced; #f
            (immutable probe $sgl-probe)   ; (sky lut mips) | #f
            (immutable cam $sgl-cam)     ; fov near far px py pz lx ly lz
            (immutable light $sgl-light) ; dx dy dz ambient
            (immutable lits $sgl-lits)   ; nodes, split by material
            (immutable texs $sgl-texs)
            (immutable pbrs $sgl-pbrs)
            ;; lit nodes sharing a geometry, two or more: each group
            ;; is #(geo nodes inst-buf inst-base cap), one draw each
            (immutable igroups $sgl-igroups)
            ;; lod containers: #(chosen-cell switches probe-node)
            (immutable lgroups $sgl-lgroups)
            (immutable iscratch $sgl-iscratch)))  ; m4s work area

  ;; geometry, shared: nodes with the SAME literal spec point at one
  ;; of these -- one upload, and the key instancing groups by.
  ;; #(vbuf ibuf vbase ibase vbytes ibytes icount uploaded? bc br)
  (define ($sgl-geo-vbuf g) (vector-ref g 0))
  (define ($sgl-geo-ibuf g) (vector-ref g 1))
  (define ($sgl-geo-icount g) (vector-ref g 6))
  (define ($sgl-geo-upload! g)          ; geometry ships on first use
    (unless (vector-ref g 7)
      (cmd-bind-buffer! ($sgl-geo-vbuf g))
      (cmd-buffer-data! (vector-ref g 2) (vector-ref g 4))
      (cmd-bind-index! ($sgl-geo-ibuf g))
      (cmd-index-data! (vector-ref g 3) (vector-ref g 5))
      (vector-set! g 7 #t)))

  (define-record-type ($sgl-node $make-sgl-node $sgl-node?)
    (fields (immutable geo $sgl-nd-geo)
            ;; px py pz rx ry rz scale r g b a metallic roughness
            (immutable f $sgl-nd-f)
            (immutable mat $sgl-nd-mat)  ; lit | tex | pbr
            (immutable tex $sgl-nd-tex)  ; texture slot | #f
            (immutable bc $sgl-nd-bc)    ; bounding sphere, local
            (immutable br $sgl-nd-br)
            ;; enclosing groups' transform fields, outermost first
            (immutable chain $sgl-nd-chain)
            ;; (chosen-cell . my-level) | #f: a lod alternative draws
            ;; only while its level is the chosen one
            (immutable lod $sgl-nd-lod)))

  ;; the instanced flavor of the lit program: the model matrix rides
  ;; four vec4 instance attributes, the color a fifth -- so a whole
  ;; group of same-geometry meshes is ONE draw, its uniforms just
  ;; u_vp and the light
  (define $sgl-inst-vs
    '((attribute vec3 a_pos)
      (attribute vec3 a_normal)
      (attribute vec4 i_m0)
      (attribute vec4 i_m1)
      (attribute vec4 i_m2)
      (attribute vec4 i_m3)
      (attribute vec4 i_color)
      (uniform mat4 u_vp)
      (varying vec3 v_normal)
      (varying vec4 v_color)
      (define (main) void
        (local mat4 m (mat4 i_m0 i_m1 i_m2 i_m3))
        (set! gl_Position (* u_vp (* m (vec4 a_pos (fl 1)))))
        (set! v_normal (vec3 (* m (vec4 a_normal (fl 0)))))
        (set! v_color i_color))))
  (define $sgl-inst-fs
    '((precision mediump float)
      (uniform vec3 u_light)
      (uniform float u_ambient)
      (varying vec3 v_normal)
      (varying vec4 v_color)
      (define (main) void
        (local vec3 n (normalize v_normal))
        (local float d (max (dot n u_light) (fl 0)))
        (local vec3 c (* v_color.rgb
                         (+ u_ambient (* d (- (fl 1) u_ambient)))))
        (set! gl_FragColor (vec4 c v_color.a)))))

  ;; a single-valued slot: a hole gets an effect, a value sets once
  (define ($sgl-set1! vec idx v ds)
    (if ($sgl-d? v)
        (let ((th (list-ref ds (cdr v))))
          (effect (lambda () (vector-set! vec idx ($sgl-fl (th))))))
        (vector-set! vec idx ($sgl-fl v))))

  (define ($sgl-set3! vec idx vals)     ; static triples
    (vector-set! vec idx ($sgl-fl (car vals)))
    (vector-set! vec (+ idx 1) ($sgl-fl (cadr vals)))
    (vector-set! vec (+ idx 2) ($sgl-fl (caddr vals))))

  (define ($sgl-cam! cam attrs ds)
    (for-each
     (lambda (a)
       (case (car a)
         ((fov) ($sgl-set1! cam 0 (cadr a) ds))
         ((near) ($sgl-set1! cam 1 (cadr a) ds))
         ((far) ($sgl-set1! cam 2 (cadr a) ds))
         ((position) ($sgl-set3! cam 3 (cdr a)))
         ((look-at) ($sgl-set3! cam 6 (cdr a)))
         (else (error 'sgl "unknown camera attribute" (car a)))))
     attrs))

  (define ($sgl-light! light attrs ds)
    (for-each
     (lambda (a)
       (case (car a)
         ((direction) ($sgl-set3! light 0 (cdr a)))
         ((ambient) ($sgl-set1! light 3 (cadr a) ds))
         (else (error 'sgl "unknown light attribute" (car a)))))
     attrs))

  (define ($sgl-geometry spec ds)
    (if ($sgl-d? spec)
        ((list-ref ds (cdr spec)))      ; injected mesh, built once
        (case (car spec)
          ((plane) (mesh-plane (cadr spec) (caddr spec)))
          ((box) (mesh-box (cadr spec) (caddr spec) (cadddr spec)))
          ((sphere) (apply mesh-sphere (cdr spec)))
          ((cylinder) (apply mesh-cylinder (cdr spec)))
          ((torus) (apply mesh-torus (cdr spec)))
          (else (error 'sgl "unknown geometry" (car spec))))))

  ;; a value that may be a hole: evaluated once at build time
  (define ($sgl-once v ds)
    (if ($sgl-d? v) ((list-ref ds (cdr v))) v))

  (define ($sgl-mat! cur want)
    (if (or (eq? cur 'lit) (eq? cur want))
        want
        (error 'sgl "one material per mesh" (list cur want))))

  (define ($sgl-mesh attrs ds chain cache lod)
    (let ((gspec #f) (mat 'lit) (tex #f)
          (f (vector 0.0 0.0 0.0 0.0 0.0 0.0 1.0
                     0.8 0.8 0.8 1.0 0.0 0.5)))
      (for-each
       (lambda (a)
         (case (car a)
           ((geometry) (set! gspec (cadr a)))
           ((texture) (set! mat ($sgl-mat! mat 'tex))
                      (set! tex ($sgl-once (cadr a) ds)))
           ((metallic) (set! mat ($sgl-mat! mat 'pbr))
                       ($sgl-set1! f 11 (cadr a) ds))
           ((roughness) (set! mat ($sgl-mat! mat 'pbr))
                        ($sgl-set1! f 12 (cadr a) ds))
           ((position) ($sgl-set3! f 0 (cdr a)))
           ((rotation) ($sgl-set3! f 3 (cdr a)))
           ((color) ($sgl-set3! f 7 (cdr a))
                    (unless (null? (cdddr (cdr a)))
                      (vector-set! f 10 ($sgl-fl (car (cdddr (cdr a)))))))
           ((position-x) ($sgl-set1! f 0 (cadr a) ds))
           ((position-y) ($sgl-set1! f 1 (cadr a) ds))
           ((position-z) ($sgl-set1! f 2 (cadr a) ds))
           ((rotation-x) ($sgl-set1! f 3 (cadr a) ds))
           ((rotation-y) ($sgl-set1! f 4 (cadr a) ds))
           ((rotation-z) ($sgl-set1! f 5 (cadr a) ds))
           ((scale) ($sgl-set1! f 6 (cadr a) ds))
           ((color-r) ($sgl-set1! f 7 (cadr a) ds))
           ((color-g) ($sgl-set1! f 8 (cadr a) ds))
           ((color-b) ($sgl-set1! f 9 (cadr a) ds))
           ((color-a) ($sgl-set1! f 10 (cadr a) ds))
           (else (error 'sgl "unknown mesh attribute" (car a)))))
       attrs)
      (unless gspec (error 'sgl "mesh needs a geometry"))
      (let* ((geo ($sgl-geo! gspec (eq? mat 'tex) ds cache))
             (bounds (vector-ref geo 8)))
        ($make-sgl-node geo f mat tex
                        (car bounds) (cdr bounds) chain lod))))

  ;; build (or find) the shared geometry for a literal spec: equal
  ;; specs with the same layout come back as the SAME vector, so
  ;; they upload once and instance together.  Injected (unquote)
  ;; meshes stay private -- each thunk is its own geometry
  (define ($sgl-geo! gspec uv? ds cache)
    (let* ((key (and (not ($sgl-d? gspec)) (cons uv? gspec)))
           (hit (and key (assoc key (car cache)))))
      (if hit
          (cdr hit)
          (let* ((geom ($sgl-geometry gspec ds))
                 (vbytes (if uv?
                             (mesh-vertex-bytes-uv geom)
                             (mesh-vertex-bytes geom)))
                 (vbuf (fx-buffer!))
                 (ibuf (fx-buffer!))
                 (vbase (fx-alloc! vbytes))
                 (ibase (fx-alloc! (mesh-index-bytes geom))))
            (if uv?
                (mesh-write-uv! geom vbase ibase)
                (mesh-write! geom vbase ibase))
            (let ((geo (vector vbuf ibuf vbase ibase
                               vbytes (mesh-index-bytes geom)
                               (mesh-index-count geom) #f
                               (mesh-bounds geom))))
              (when key
                (set-car! cache (cons (cons key geo) (car cache))))
              geo)))))


  ;; a group's transform fields: px py pz rx ry rz scale, holes
  ;; welcome in the single-valued ones
  (define ($sgl-group-f attrs ds)
    (let ((f (vector 0.0 0.0 0.0 0.0 0.0 0.0 1.0)))
      (for-each
       (lambda (a)
         (case (car a)
           ((position) ($sgl-set3! f 0 (cdr a)))
           ((rotation) ($sgl-set3! f 3 (cdr a)))
           ((position-x) ($sgl-set1! f 0 (cadr a) ds))
           ((position-y) ($sgl-set1! f 1 (cadr a) ds))
           ((position-z) ($sgl-set1! f 2 (cadr a) ds))
           ((rotation-x) ($sgl-set1! f 3 (cadr a) ds))
           ((rotation-y) ($sgl-set1! f 4 (cadr a) ds))
           ((rotation-z) ($sgl-set1! f 5 (cadr a) ds))
           ((scale) ($sgl-set1! f 6 (cadr a) ds))
           (else (error 'sgl "unknown group attribute" (car a)))))
       attrs)
      f))

  (define ($sgl-probe! attrs ds)
    (let ((sky #f) (lut #f) (mips 0.0))
      (for-each
       (lambda (a)
         (case (car a)
           ((sky) (set! sky ($sgl-once (cadr a) ds)))
           ((lut) (set! lut ($sgl-once (cadr a) ds)))
           ((mips) (set! mips ($sgl-fl ($sgl-once (cadr a) ds))))
           (else (error 'sgl "unknown probe attribute" (car a)))))
       attrs)
      (unless (and sky lut) (error 'sgl "probe needs sky and lut"))
      (vector sky lut mips)))

  (define ($sgl-build forms ds)         ; needs fx-init! first
    (let ((cam (vector 0.9 0.1 100.0 0.0 2.0 8.0 0.0 0.0 0.0))
          (light (vector 0.5 0.8 0.4 0.25))
          (probe #f)
          (cache (list '()))            ; spec -> shared geometry
          (lgroups '())
          (meshes '()))
      ;; groups nest, so the walk recurses carrying the transform
      ;; chain (outermost first) every mesh inside inherits
      (let walk ((forms forms) (chain '()))
        (for-each
         (lambda (f)
           (let* ((attrs? (and (pair? (cdr f)) (pair? (cadr f))
                               (eq? (car (cadr f)) '@)))
                  (attrs (if attrs? (cdr (cadr f)) '()))
                  (kids (if attrs? (cddr f) (cdr f))))
             (case (car f)
               ((camera) ($sgl-cam! cam attrs ds))
               ((light) ($sgl-light! light attrs ds))
               ((probe) (set! probe ($sgl-probe! attrs ds)))
               ((group)
                (walk kids
                      (append chain (list ($sgl-group-f attrs ds)))))
               ((mesh) (set! meshes
                             (cons ($sgl-mesh attrs ds chain cache #f)
                                   meshes)))
               ((lod)
                ;; children are detail levels of one thing: distance
                ;; under (switch d1 d2 ...) picks which one draws
                (let ((cell (vector 0))
                      (sw (let find ((as attrs))
                            (cond ((null? as)
                                   (error 'sgl "lod needs (switch ...)"))
                                  ((eq? (car (car as)) 'switch)
                                   (map $sgl-fl (cdr (car as))))
                                  (else (find (cdr as)))))))
                  (let level ((ks kids) (i 0) (first #f))
                    (if (pair? ks)
                        (let* ((k (car ks))
                               (kattrs (if (and (pair? (cdr k))
                                                (pair? (cadr k))
                                                (eq? (car (cadr k)) '@))
                                           (cdr (cadr k))
                                           '()))
                               (nd (if (eq? (car k) 'mesh)
                                       ($sgl-mesh kattrs ds chain cache
                                                  (cons cell i))
                                       (error 'sgl
                                              "lod children are meshes"
                                              (car k)))))
                          (set! meshes (cons nd meshes))
                          (level (cdr ks) (+ i 1) (or first nd)))
                        (set! lgroups
                              (cons (vector cell sw first) lgroups))))))
               (else (error 'sgl "unknown tag" (car f))))))
         forms))
      ;; split by material; each program exists only if a mesh asks
      (let loop ((ms (reverse meshes)) (lits '()) (texs '()) (pbrs '()))
        (if (pair? ms)
            (case ($sgl-nd-mat (car ms))
              ((tex) (loop (cdr ms) lits (cons (car ms) texs) pbrs))
              ((pbr) (loop (cdr ms) lits texs (cons (car ms) pbrs)))
              (else (loop (cdr ms) (cons (car ms) lits) texs pbrs)))
            (begin
              (when (and (pair? pbrs) (not probe))
                (error 'sgl "pbr meshes need a probe tag"))
              (let-values (((groups singles)
                            ($sgl-igroups! (reverse lits))))
                ($make-sgl
                 (and (pair? singles)
                      (fx-program! mesh-lit-vs mesh-lit-fs))
                 (and (pair? texs) (fx-program! mesh-tex-vs mesh-tex-fs))
                 (and (pair? pbrs) (fx-program! mesh-pbr-vs mesh-pbr-fs))
                 (and (pair? groups)
                      (fx-program! $sgl-inst-vs $sgl-inst-fs))
                 probe cam light
                 singles (reverse texs) (reverse pbrs)
                 groups
                 (reverse lgroups)
                 ;; 0..192 model-into work area, 192..256 lod probe,
                 ;; 256..320 cull SoA (xs ys zs rs), 320 center quad,
                 ;; 336 the ones quad (set once here), 352 plane quad
                 (let ((scr (if (or (pair? groups) (pair? lgroups))
                                (fx-alloc! 384)
                                0)))
                   (when (> scr 0)
                     (%mem-f32-set! (+ scr 336) 1.0)
                     (%mem-f32-set! (+ scr 340) 1.0)
                     (%mem-f32-set! (+ scr 344) 1.0)
                     (%mem-f32-set! (+ scr 348) 1.0))
                   scr))))))))

  ;; lit nodes sharing a geometry, two or more, become an instanced
  ;; group -- one buffer of matrix+color per instance, one draw
  (define ($sgl-igroups! lits)
    (let outer ((ns lits) (grouped '()) (groups '()) (singles '()))
      (cond
       ((null? ns) (values (reverse groups) (reverse singles)))
       ((memq ($sgl-nd-geo (car ns)) grouped)
        (outer (cdr ns) grouped groups singles))
       (else
        (let* ((g ($sgl-nd-geo (car ns)))
               (mine (let pick ((k lits) (acc '()))
                       (cond ((null? k) (reverse acc))
                             ((eq? ($sgl-nd-geo (car k)) g)
                              (pick (cdr k) (cons (car k) acc)))
                             (else (pick (cdr k) acc))))))
          (if (null? (cdr mine))
              (outer (cdr ns) grouped groups (cons (car ns) singles))
              (outer (cdr ns) (cons g grouped)
                     (cons (vector g mine (fx-buffer!)
                                   (fx-alloc! (* (length mine) 80))
                                   (length mine))
                           groups)
                     singles)))))))

  ;; ---- a frame: pure arithmetic over the current fields ----
  ;; the TRS matrix any 7-field transform vector describes
  (define ($sgl-trs f)
    (let ((s (vector-ref f 6)))
      (m4-mul (m4-translate (vector-ref f 0) (vector-ref f 1)
                            (vector-ref f 2))
              (m4-mul (m4-rotate-y (vector-ref f 4))
                      (m4-mul (m4-rotate-x (vector-ref f 3))
                              (m4-mul (m4-rotate-z (vector-ref f 5))
                                      (m4-scale s s s)))))))

  ;; The model matrix -- the group chain's transforms, then the
  ;; node's own -- places the bounding sphere; a node the frustum
  ;; cannot see costs exactly this arithmetic and no commands.
  ;; a lod alternative draws only while its level is chosen
  (define ($sgl-lod-active? nd)
    (let ((l ($sgl-nd-lod nd)))
      (or (not l) (= (vector-ref (car l) 0) (cdr l)))))

  (define ($sgl-draw-node! prog vp planes nd)
    (when ($sgl-lod-active? nd)
      ($sgl-draw-node*! prog vp planes nd)))

  (define ($sgl-draw-node*! prog vp planes nd)
    (let* ((f ($sgl-nd-f nd))
           (geo ($sgl-nd-geo nd))
           (model (fold-left (lambda (acc gf) (m4-mul acc ($sgl-trs gf)))
                             (m4-identity) ($sgl-nd-chain nd)))
           (model (m4-mul model ($sgl-trs f)))
           (s (fold-left (lambda (acc gf) (fl* acc (vector-ref gf 6)))
                         (vector-ref f 6) ($sgl-nd-chain nd))))
      (when ($sgl-in-frustum-m4? planes model ($sgl-nd-bc nd)
                                 (fl* s ($sgl-nd-br nd)))
        (fx-use! prog ($sgl-geo-vbuf geo))
        ($sgl-geo-upload! geo)
        (cmd-bind-index! ($sgl-geo-ibuf geo))
        (when ($sgl-nd-tex nd)
          (cmd-bind-texture! 0 ($sgl-nd-tex nd)))
        (fx-uniform! prog 'u_mvp (m4-mul vp model))
        (fx-uniform! prog 'u_model model)
        (if (eq? ($sgl-nd-mat nd) 'pbr)
            (begin
              (fx-uniform! prog 'u_albedo (vector-ref f 7) (vector-ref f 8)
                           (vector-ref f 9) (vector-ref f 10))
              (fx-uniform! prog 'u_metallic (vector-ref f 11))
              (fx-uniform! prog 'u_roughness (vector-ref f 12)))
            (fx-uniform! prog 'u_color (vector-ref f 7) (vector-ref f 8)
                         (vector-ref f 9) (vector-ref f 10)))
        (cmd-draw-elements! GL-TRIANGLES ($sgl-geo-icount geo)))))

  ;; ---- the instanced path: staging all the way down ----
  ;; the node's TRS composes in closed form (m4s-trs!), the chain
  ;; multiplies in SIMD (m4s-mul!), and the result lands DIRECTLY in
  ;; the instance buffer slot -- no boxed matrix exists at any point
  (define ($sgl-f-trs! f at)
    (m4s-trs! at (vector-ref f 0) (vector-ref f 1) (vector-ref f 2)
              (vector-ref f 3) (vector-ref f 4) (vector-ref f 5)
              (vector-ref f 6)))

  (define ($sgl-model-into! nd at s)    ; s: 192 bytes of work area
    (let* ((f ($sgl-nd-f nd))
           (chain ($sgl-nd-chain nd))
           (n-ch (length chain)))
      (if (= n-ch 0)
          ($sgl-f-trs! f at)
          (let ((sg s) (sa (+ s 64)) (sb (+ s 128)))
            ($sgl-f-trs! f sa)
            ;; innermost group first; the last multiply lands on `at`
            (let fold ((gs (reverse chain)) (i 0) (acc sa))
              (when (pair? gs)
                ($sgl-f-trs! (car gs) sg)
                (let ((dst (if (= i (- n-ch 1))
                               at
                               (if (= acc sa) sb sa))))
                  (m4s-mul! dst sg acc)
                  (fold (cdr gs) (+ i 1) dst))))))))

  ;; cull tests without a boxed center: the transformed center's
  ;; coordinates flow straight into sphere-in-frustum-xyz? as scalars
  (define ($sgl-in-frustum-m4? planes m bc r) ; m: boxed mat4
    (let ((x (v3-x bc)) (y (v3-y bc)) (z (v3-z bc)))
      (sphere-in-frustum-xyz?
       planes
       (fl+ (fl+ (fl* (vector-ref m 0) x) (fl* (vector-ref m 4) y))
            (fl+ (fl* (vector-ref m 8) z) (vector-ref m 12)))
       (fl+ (fl+ (fl* (vector-ref m 1) x) (fl* (vector-ref m 5) y))
            (fl+ (fl* (vector-ref m 9) z) (vector-ref m 13)))
       (fl+ (fl+ (fl* (vector-ref m 2) x) (fl* (vector-ref m 6) y))
            (fl+ (fl* (vector-ref m 10) z) (vector-ref m 14)))
       r)))

  ;; ---- the batched cull: four spheres a pop ----
  ;; centers and radii lay out SoA -- xs ys zs rs, one f32x4 each --
  ;; and every plane tests all four in five SIMD instructions:
  ;; xs*nx + ys*ny + zs*nz + rs + d, positive lanes still visible.
  ;; A lane that dies stops being read; a plane that kills all four
  ;; stops the walk
  (define $sgl-vis (make-vector 4 #f))
  (define $sgl-chunk (make-vector 4 #f))

  (define ($sgl-cull4! planes soa ones res m)
    (let init ((k 0))
      (when (< k 4)
        (vector-set! $sgl-vis k (< k m))
        (init (+ k 1))))
    (let plane ((i 0))
      (when (< i 6)
        (let ((p (vector-ref planes i)))
          (%f32x4-scale! res soa (vector-ref p 0))
          (%f32x4-axpy! res res (+ soa 16) (vector-ref p 1))
          (%f32x4-axpy! res res (+ soa 32) (vector-ref p 2))
          (%f32x4-axpy! res res (+ soa 48) 1.0)
          (%f32x4-axpy! res res ones (vector-ref p 3))
          (let lane ((k 0) (any #f))
            (if (= k 4)
                (when any (plane (+ i 1)))
                (lane (+ k 1)
                      (or (and (vector-ref $sgl-vis k)
                               (if (fl<? 0.0 (%mem-f32-ref
                                              (+ res (* k 4))))
                                   #t
                                   (begin (vector-set! $sgl-vis k #f)
                                          #f)))
                          any))))))))

  (define ($sgl-m4s-copy! dst src)      ; scale by one: 4 lanes a pop
    (%f32x4-scale! dst src 1.0)
    (%f32x4-scale! (+ dst 16) (+ src 16) 1.0)
    (%f32x4-scale! (+ dst 32) (+ src 32) 1.0)
    (%f32x4-scale! (+ dst 48) (+ src 48) 1.0))

  ;; one group: compose every instance into candidate slots four at
  ;; a time, batch-cull them in SIMD, pack the visible down (a chunk
  ;; with nothing culled moves nothing), one upload, one draw
  (define ($sgl-draw-igroup! prog ig planes scratch)
    (let* ((geo (vector-ref ig 0))
           (ibuf (vector-ref ig 2))
           (ibase (vector-ref ig 3))
           (soa (+ scratch 256))
           (ctr (+ scratch 320))
           (ones (+ scratch 336))
           (res (+ scratch 352))
           (flush!
            (lambda (n)
              (when (> n 0)
                (fx-use-instanced! prog ($sgl-geo-vbuf geo) ibuf)
                ($sgl-geo-upload! geo)
                (cmd-bind-index! ($sgl-geo-ibuf geo))
                (cmd-bind-buffer! ibuf)
                (cmd-buffer-data! ibase (* n 80))
                (cmd-draw-elements-instanced!
                 GL-TRIANGLES ($sgl-geo-icount geo) n)))))
      (let fill ((ns (vector-ref ig 1)) (n 0))
        (let gather ((ns ns) (m 0))     ; next four lod-active nodes
          (if (and (pair? ns) (< m 4))
              (if ($sgl-lod-active? (car ns))
                  (begin (vector-set! $sgl-chunk m (car ns))
                         (gather (cdr ns) (+ m 1)))
                  (gather (cdr ns) m))
              (if (= m 0)
                  (flush! n)
                  (begin
                    ;; compose into candidate slots n..n+m-1; the
                    ;; center is the slot's columns recombined in
                    ;; SIMD (M.c0*bx + M.c1*by + M.c2*bz + M.c3)
                    (let comp ((k 0))
                      (when (< k m)
                        (let* ((nd (vector-ref $sgl-chunk k))
                               (f ($sgl-nd-f nd))
                               (bc ($sgl-nd-bc nd))
                               (slot (+ ibase (* (+ n k) 80))))
                          ($sgl-model-into! nd slot scratch)
                          (%f32x4-scale! ctr slot (v3-x bc))
                          (%f32x4-axpy! ctr ctr (+ slot 16) (v3-y bc))
                          (%f32x4-axpy! ctr ctr (+ slot 32) (v3-z bc))
                          (%f32x4-axpy! ctr ctr (+ slot 48) 1.0)
                          (%mem-f32-set! (+ soa (* k 4))
                                         (%mem-f32-ref ctr))
                          (%mem-f32-set! (+ (+ soa 16) (* k 4))
                                         (%mem-f32-ref (+ ctr 4)))
                          (%mem-f32-set! (+ (+ soa 32) (* k 4))
                                         (%mem-f32-ref (+ ctr 8)))
                          (%mem-f32-set!
                           (+ (+ soa 48) (* k 4))
                           (fl* (fold-left
                                 (lambda (acc gf)
                                   (fl* acc (vector-ref gf 6)))
                                 (vector-ref f 6)
                                 ($sgl-nd-chain nd))
                                ($sgl-nd-br nd))))
                        (comp (+ k 1))))
                    ($sgl-cull4! planes soa ones res m)
                    ;; pack visible ones down; dst never passes src
                    (let pack ((k 0) (n2 n))
                      (if (= k m)
                          (if (pair? ns)
                              (fill ns n2)
                              (flush! n2))
                          (if (vector-ref $sgl-vis k)
                              (let* ((nd (vector-ref $sgl-chunk k))
                                     (f ($sgl-nd-f nd))
                                     (src (+ ibase (* (+ n k) 80)))
                                     (dst (+ ibase (* n2 80))))
                                (unless (= src dst)
                                  ($sgl-m4s-copy! dst src))
                                (%mem-f32-set! (+ dst 64)
                                               (vector-ref f 7))
                                (%mem-f32-set! (+ dst 68)
                                               (vector-ref f 8))
                                (%mem-f32-set! (+ dst 72)
                                               (vector-ref f 9))
                                (%mem-f32-set! (+ dst 76)
                                               (vector-ref f 10))
                                (pack (+ k 1) (+ n2 1)))
                              (pack (+ k 1) n2)))))))))))

  (define (sgl-draw! sc)
    (let* ((cam ($sgl-cam sc))
           (light ($sgl-light sc))
           (aspect (fl/ ($sgl-fl (fx-width)) ($sgl-fl (fx-height))))
           (eye (v3 (vector-ref cam 3) (vector-ref cam 4)
                    (vector-ref cam 5)))
           (vp (m4-mul
                (m4-perspective (vector-ref cam 0) aspect
                                (vector-ref cam 1) (vector-ref cam 2))
                (m4-look-at
                 eye
                 (v3 (vector-ref cam 6) (vector-ref cam 7) (vector-ref cam 8))
                 (v3 0.0 1.0 0.0))))
           (planes (m4-frustum-planes vp))
           (ld (v3-normalize (v3 (vector-ref light 0) (vector-ref light 1)
                                 (vector-ref light 2)))))
      (cmd-depth! #t)
      ;; lod containers pick their level: the probe node's staged
      ;; matrix places the thing, and its distance to the eye walks
      ;; the switch list
      (for-each
       (lambda (lg)
         (let* ((sscr ($sgl-iscratch sc))
                (at (+ sscr 192)))
           ($sgl-model-into! (vector-ref lg 2) at sscr)
           (let* ((dx (fl- (%mem-f32-ref (+ at 48)) (v3-x eye)))
                  (dy (fl- (%mem-f32-ref (+ at 52)) (v3-y eye)))
                  (dz (fl- (%mem-f32-ref (+ at 56)) (v3-z eye)))
                  (d (flsqrt (fl+ (fl* dx dx)
                                  (fl+ (fl* dy dy) (fl* dz dz))))))
             (vector-set! (vector-ref lg 0) 0
                          (let walk ((sw (vector-ref lg 1)) (i 0))
                            (cond ((null? sw) i)
                                  ((fl<? d (car sw)) i)
                                  (else (walk (cdr sw) (+ i 1)))))))))
       ($sgl-lgroups sc))
      ;; instanced groups first: one draw per shared geometry
      (when ($sgl-iprog sc)
        (let ((p ($sgl-iprog sc)))
          (cmd-use-program! (fx-program-slot p))
          (fx-uniform! p 'u_light (v3-x ld) (v3-y ld) (v3-z ld))
          (fx-uniform! p 'u_ambient (vector-ref light 3))
          (fx-uniform! p 'u_vp vp)
          (for-each (lambda (ig)
                      ($sgl-draw-igroup! p ig planes
                                         ($sgl-iscratch sc)))
                    ($sgl-igroups sc))))
      ($sgl-group! ($sgl-prog sc) ($sgl-lits sc) vp planes ld
                   (lambda (p)
                     (fx-uniform! p 'u_ambient (vector-ref light 3))))
      ($sgl-group! ($sgl-tprog sc) ($sgl-texs sc) vp planes ld
                   (lambda (p)
                     (fx-uniform! p 'u_ambient (vector-ref light 3))
                     (fx-uniform! p 'u_tex 0)))
      ($sgl-group! ($sgl-pprog sc) ($sgl-pbrs sc) vp planes ld
                   (lambda (p)
                     (let ((probe ($sgl-probe sc)))
                       (cmd-bind-cubemap! 0 (vector-ref probe 0))
                       (cmd-bind-texture! 1 (vector-ref probe 1))
                       (fx-uniform! p 'u_sky 0)
                       (fx-uniform! p 'u_lut 1)
                       (fx-uniform! p 'u_mips (vector-ref probe 2))
                       (fx-uniform! p 'u_eye (v3-x eye) (v3-y eye)
                                    (v3-z eye)))))))

  ;; one material's pass: the shared uniforms once, then each node
  (define ($sgl-group! prog nodes vp planes ld setup!)
    (when (pair? nodes)
      (cmd-use-program! (fx-program-slot prog))
      (fx-uniform! prog 'u_light (v3-x ld) (v3-y ld) (v3-z ld))
      (setup! prog)
      (for-each (lambda (nd) ($sgl-draw-node! prog vp planes nd))
                nodes))))
