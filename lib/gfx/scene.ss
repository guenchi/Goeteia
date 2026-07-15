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
                   ;; a malformed child ((group () ...) instead of
                   ;; (group (@) ...)) used to trap on (car '()) --
                   ;; name the offender and the fix instead
                   (unless (and (pair? f) (symbol? (car f)))
                     (error 'sgl
                            "form must be (tag (@ attrs ...) kids ...)"
                            f))
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
            (immutable iscratch $sgl-iscratch)   ; m4s work area
            ;; the Env uniform block: every program reads the frame
            ;; globals (vp, light, ambient, eye) from binding 0 --
            ;; one 96-byte upload a frame instead of per-program sends
            (immutable env $sgl-env)             ; ubo slot
            (immutable envat $sgl-envat)))       ; staging base

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
            (immutable lod $sgl-nd-lod)
            ;; the matrix cache: cgen is the chain+own generation sum
            ;; it was built against (-1 = never); a static node
            ;; composes once, ever.  Instanced nodes cache in staging
            ;; at cbase (matrix, world center, world radius -- 80
            ;; bytes); singles cache the boxed model and scale
            (mutable cgen $sgl-nd-cgen $sgl-nd-cgen!)
            (mutable cbase $sgl-nd-cbase $sgl-nd-cbase!)
            (mutable cmodel $sgl-nd-cmodel $sgl-nd-cmodel!)
            (mutable cscale $sgl-nd-cscale $sgl-nd-cscale!)))

  ;; the generation a node's model matrix depends on: its own
  ;; transform fields' plus every enclosing group's
  (define ($sgl-node-gen nd)
    (fold-left (lambda (g gf) (+ g (vector-ref gf 7)))
               (vector-ref ($sgl-nd-f nd) 13)
               ($sgl-nd-chain nd)))

  ;; ---- the Env block: frame globals, uploaded once ----
  ;; std140: mat4 at 0, vec3 u_light at 64 with u_ambient packed in
  ;; its fourth float (76), vec3 u_eye at 80 -- 96 bytes.  Shaders
  ;; keep their variable names, so envify is a pure declaration swap:
  ;; drop the classic uniform forms the block now carries, put the
  ;; block first
  (define $sgl-env-block
    '(uniform-block Env
                    (mat4 u_vp)
                    (vec3 u_light)
                    (float u_ambient)
                    (vec3 u_eye)))

  (define ($sgl-envify forms)
    (cons $sgl-env-block
          (filter (lambda (f)
                    (not (and (pair? f) (eq? (car f) 'uniform)
                              (memq (caddr f)
                                    '(u_vp u_light u_ambient u_eye)))))
                  forms)))

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
  ;; gen: the vector's generation slot, bumped when a hole rewrites
  ;; a transform field -- consumers cache matrices against it.
  ;; #f for fields (camera, light, colors) no matrix depends on
  (define ($sgl-set1! vec idx v ds gen)
    (if ($sgl-d? v)
        (let ((th (list-ref ds (cdr v))))
          (effect (lambda ()
                    (vector-set! vec idx ($sgl-fl (th)))
                    (when gen
                      (vector-set! vec gen
                                   (+ 1 (vector-ref vec gen)))))))
        (vector-set! vec idx ($sgl-fl v))))

  (define ($sgl-set3! vec idx vals)     ; static triples
    (vector-set! vec idx ($sgl-fl (car vals)))
    (vector-set! vec (+ idx 1) ($sgl-fl (cadr vals)))
    (vector-set! vec (+ idx 2) ($sgl-fl (caddr vals))))

  (define ($sgl-cam! cam attrs ds)
    (for-each
     (lambda (a)
       (case (car a)
         ((fov) ($sgl-set1! cam 0 (cadr a) ds #f))
         ((near) ($sgl-set1! cam 1 (cadr a) ds #f))
         ((far) ($sgl-set1! cam 2 (cadr a) ds #f))
         ((position) ($sgl-set3! cam 3 (cdr a)))
         ((look-at) ($sgl-set3! cam 6 (cdr a)))
         (else (error 'sgl "unknown camera attribute" (car a)))))
     attrs))

  (define ($sgl-light! light attrs ds)
    (for-each
     (lambda (a)
       (case (car a)
         ((direction) ($sgl-set3! light 0 (cdr a)))
         ((ambient) ($sgl-set1! light 3 (cadr a) ds #f))
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
          ;; last slot: the transform generation matrix caches watch
          (f (vector 0.0 0.0 0.0 0.0 0.0 0.0 1.0
                     0.8 0.8 0.8 1.0 0.0 0.5 0)))
      (for-each
       (lambda (a)
         (case (car a)
           ((geometry) (set! gspec (cadr a)))
           ((texture) (set! mat ($sgl-mat! mat 'tex))
                      (set! tex ($sgl-once (cadr a) ds)))
           ((metallic) (set! mat ($sgl-mat! mat 'pbr))
                       ($sgl-set1! f 11 (cadr a) ds #f))
           ((roughness) (set! mat ($sgl-mat! mat 'pbr))
                        ($sgl-set1! f 12 (cadr a) ds #f))
           ((position) ($sgl-set3! f 0 (cdr a)))
           ((rotation) ($sgl-set3! f 3 (cdr a)))
           ((color) ($sgl-set3! f 7 (cdr a))
                    (unless (null? (cdddr (cdr a)))
                      (vector-set! f 10 ($sgl-fl (car (cdddr (cdr a)))))))
           ((position-x) ($sgl-set1! f 0 (cadr a) ds 13))
           ((position-y) ($sgl-set1! f 1 (cadr a) ds 13))
           ((position-z) ($sgl-set1! f 2 (cadr a) ds 13))
           ((rotation-x) ($sgl-set1! f 3 (cadr a) ds 13))
           ((rotation-y) ($sgl-set1! f 4 (cadr a) ds 13))
           ((rotation-z) ($sgl-set1! f 5 (cadr a) ds 13))
           ((scale) ($sgl-set1! f 6 (cadr a) ds 13))
           ((color-r) ($sgl-set1! f 7 (cadr a) ds #f))
           ((color-g) ($sgl-set1! f 8 (cadr a) ds #f))
           ((color-b) ($sgl-set1! f 9 (cadr a) ds #f))
           ((color-a) ($sgl-set1! f 10 (cadr a) ds #f))
           (else (error 'sgl "unknown mesh attribute" (car a)))))
       attrs)
      (unless gspec (error 'sgl "mesh needs a geometry"))
      (let* ((geo ($sgl-geo! gspec (eq? mat 'tex) ds cache))
             (bounds (vector-ref geo 8)))
        ($make-sgl-node geo f mat tex
                        (car bounds) (cdr bounds) chain lod
                        -1 0 #f 1.0))))

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
    ;; last slot: the transform generation
    (let ((f (vector 0.0 0.0 0.0 0.0 0.0 0.0 1.0 0)))
      (for-each
       (lambda (a)
         (case (car a)
           ((position) ($sgl-set3! f 0 (cdr a)))
           ((rotation) ($sgl-set3! f 3 (cdr a)))
           ((position-x) ($sgl-set1! f 0 (cadr a) ds 7))
           ((position-y) ($sgl-set1! f 1 (cadr a) ds 7))
           ((position-z) ($sgl-set1! f 2 (cadr a) ds 7))
           ((rotation-x) ($sgl-set1! f 3 (cadr a) ds 7))
           ((rotation-y) ($sgl-set1! f 4 (cadr a) ds 7))
           ((rotation-z) ($sgl-set1! f 5 (cadr a) ds 7))
           ((scale) ($sgl-set1! f 6 (cadr a) ds 7))
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
              (let-values (((groups singles*)
                            ($sgl-igroups! (reverse lits))))
                (define singles ($sgl-weld! singles*))
                (let* ((env! (lambda (p)     ; wire Env to binding 0
                               (when p
                                 (gl-uniform-block!
                                  (fx-program-slot p) "Env" 0))
                               p))
                       (prog (env! (and (pair? singles)
                                        (fx-program3!
                                         ($sgl-envify mesh-lit-vs)
                                         ($sgl-envify mesh-lit-fs)))))
                       (tprog (env! (and (pair? texs)
                                         (fx-program3!
                                          ($sgl-envify mesh-tex-vs)
                                          ($sgl-envify mesh-tex-fs)))))
                       (pprog (env! (and (pair? pbrs)
                                         (fx-program3!
                                          ($sgl-envify mesh-pbr-vs)
                                          ($sgl-envify mesh-pbr-fs)))))
                       (iprog (env! (and (pair? groups)
                                         (fx-program3!
                                          ($sgl-envify $sgl-inst-vs)
                                          ($sgl-envify $sgl-inst-fs))))))
                ($make-sgl
                 prog tprog pprog iprog
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
                   scr)
                 (fx-ubo! 96)
                 (fx-alloc! 96)))))))))

  ;; ---- static batching: strangers welded into one draw ----
  ;; Signal-driven holes ran their effects at build, so a node whose
  ;; transform generations all read zero is provably static.  Static
  ;; lit singles of the same color bake their model matrices into
  ;; fresh vertex data (positions transformed, normals rotated and
  ;; renormalized) and weld into ONE geometry drawn by ONE node with
  ;; the identity transform -- different shapes, one draw.  The
  ;; welded bounding sphere is the conservative hull of the parts
  (define ($sgl-static? nd)
    (and (not ($sgl-nd-lod nd))
         (= 0 (vector-ref ($sgl-nd-f nd) 13))
         (let chain ((gs ($sgl-nd-chain nd)))
           (or (null? gs)
               (and (= 0 (vector-ref (car gs) 7))
                    (chain (cdr gs)))))))

  (define ($sgl-node-model nd)          ; static: safe to fold now
    (m4-mul (fold-left (lambda (acc gf) (m4-mul acc ($sgl-trs gf)))
                       (m4-identity) ($sgl-nd-chain nd))
            ($sgl-trs ($sgl-nd-f nd))))

  (define ($sgl-weld nodes)             ; two or more static, same color
    (let* ((total-v (fold-left (lambda (a nd)
                                 (+ a (quotient
                                       (vector-ref ($sgl-nd-geo nd) 4)
                                       24)))
                               0 nodes))
           (total-i (fold-left (lambda (a nd)
                                 (+ a (vector-ref ($sgl-nd-geo nd) 6)))
                               0 nodes))
           (vbuf (fx-buffer!))
           (ibuf (fx-buffer!))
           (vbase (fx-alloc! (* total-v 24)))
           (ibase (fx-alloc! (* 4 (quotient (+ total-i 1) 2)))))
      ;; bake each node's vertices; indices shift by the running base
      (let weld ((ns nodes) (v0 0) (i0 0)
                 (cx 0.0) (cy 0.0) (cz 0.0))
        (if (pair? ns)
            (let* ((nd (car ns))
                   (geo ($sgl-nd-geo nd))
                   (m ($sgl-node-model nd))
                   (src (vector-ref geo 2))
                   (nsrc (quotient (vector-ref geo 4) 24))
                   (isrc (vector-ref geo 3))
                   (icnt (vector-ref geo 6)))
              (let vtx ((k 0))
                (when (< k nsrc)
                  (let* ((at (+ src (* k 24)))
                         (x (%mem-f32-ref at))
                         (y (%mem-f32-ref (+ at 4)))
                         (z (%mem-f32-ref (+ at 8)))
                         (nx (%mem-f32-ref (+ at 12)))
                         (ny (%mem-f32-ref (+ at 16)))
                         (nz (%mem-f32-ref (+ at 20)))
                         (out (+ vbase (* (+ v0 k) 24)))
                         (tx (fl+ (fl+ (fl* (vector-ref m 0) x)
                                       (fl* (vector-ref m 4) y))
                                  (fl+ (fl* (vector-ref m 8) z)
                                       (vector-ref m 12))))
                         (ty (fl+ (fl+ (fl* (vector-ref m 1) x)
                                       (fl* (vector-ref m 5) y))
                                  (fl+ (fl* (vector-ref m 9) z)
                                       (vector-ref m 13))))
                         (tz (fl+ (fl+ (fl* (vector-ref m 2) x)
                                       (fl* (vector-ref m 6) y))
                                  (fl+ (fl* (vector-ref m 10) z)
                                       (vector-ref m 14))))
                         (rx (fl+ (fl+ (fl* (vector-ref m 0) nx)
                                       (fl* (vector-ref m 4) ny))
                                  (fl* (vector-ref m 8) nz)))
                         (ry (fl+ (fl+ (fl* (vector-ref m 1) nx)
                                       (fl* (vector-ref m 5) ny))
                                  (fl* (vector-ref m 9) nz)))
                         (rz (fl+ (fl+ (fl* (vector-ref m 2) nx)
                                       (fl* (vector-ref m 6) ny))
                                  (fl* (vector-ref m 10) nz)))
                         (len (flsqrt (fl+ (fl+ (fl* rx rx)
                                                (fl* ry ry))
                                           (fl* rz rz)))))
                    (%mem-f32-set! out tx)
                    (%mem-f32-set! (+ out 4) ty)
                    (%mem-f32-set! (+ out 8) tz)
                    (%mem-f32-set! (+ out 12) (fl/ rx len))
                    (%mem-f32-set! (+ out 16) (fl/ ry len))
                    (%mem-f32-set! (+ out 20) (fl/ rz len)))
                  (vtx (+ k 1))))
              (let idx ((k 0))
                (when (< k icnt)
                  (let* ((w (%mem-i32-ref (+ isrc (* 4 (quotient k 2)))))
                         (half (if (= 0 (remainder k 2))
                                   (remainder w 65536)
                                   (quotient w 65536)))
                         (v (+ half v0))
                         (oat (+ ibase (* 2 (+ i0 k))))
                         )
                    (%mem-u8-set! oat (remainder v 256))
                    (%mem-u8-set! (+ oat 1) (quotient v 256)))
                  (idx (+ k 1))))
              (weld (cdr ns) (+ v0 nsrc) (+ i0 icnt)
                    ;; running centroid of part centers, for the hull
                    (fl+ cx (fl* (vector-ref m 12) 1.0))
                    (fl+ cy (vector-ref m 13))
                    (fl+ cz (vector-ref m 14))))
            ;; the welded node: identity transform, hull bounds
            (let* ((n (fixnum->flonum (length nodes)))
                   (bx (fl/ cx n)) (by (fl/ cy n)) (bz (fl/ cz n))
                   (br (fold-left
                        (lambda (r nd)
                          (let* ((m ($sgl-node-model nd))
                                 (bc ($sgl-nd-bc nd))
                                 (s (fold-left
                                     (lambda (a gf)
                                       (fl* a (vector-ref gf 6)))
                                     (vector-ref ($sgl-nd-f nd) 6)
                                     ($sgl-nd-chain nd)))
                                 (px (fl+ (fl+ (fl* (vector-ref m 0)
                                                    (v3-x bc))
                                               (fl* (vector-ref m 4)
                                                    (v3-y bc)))
                                          (fl+ (fl* (vector-ref m 8)
                                                    (v3-z bc))
                                               (vector-ref m 12))))
                                 (py (fl+ (fl+ (fl* (vector-ref m 1)
                                                    (v3-x bc))
                                               (fl* (vector-ref m 5)
                                                    (v3-y bc)))
                                          (fl+ (fl* (vector-ref m 9)
                                                    (v3-z bc))
                                               (vector-ref m 13))))
                                 (pz (fl+ (fl+ (fl* (vector-ref m 2)
                                                    (v3-x bc))
                                               (fl* (vector-ref m 6)
                                                    (v3-y bc)))
                                          (fl+ (fl* (vector-ref m 10)
                                                    (v3-z bc))
                                               (vector-ref m 14))))
                                 (dx (fl- px bx)) (dy (fl- py by))
                                 (dz (fl- pz bz))
                                 (d (fl+ (flsqrt
                                          (fl+ (fl+ (fl* dx dx)
                                                    (fl* dy dy))
                                               (fl* dz dz)))
                                         (fl* s ($sgl-nd-br nd)))))
                            (if (fl<? r d) d r)))
                        0.0 nodes))
                   (f0 ($sgl-nd-f (car nodes)))
                   (geo (vector vbuf ibuf vbase ibase
                                (* total-v 24)
                                (* 4 (quotient (+ total-i 1) 2))
                                total-i #f
                                (cons (v3 0.0 0.0 0.0) 1.0))))
              ($make-sgl-node geo
                              (vector 0.0 0.0 0.0 0.0 0.0 0.0 1.0
                                      (vector-ref f0 7)
                                      (vector-ref f0 8)
                                      (vector-ref f0 9)
                                      (vector-ref f0 10)
                                      0.0 0.5 0)
                              'lit #f
                              (v3 bx by bz) br
                              '() #f
                              -1 0 #f 1.0))))))

  ;; partition lit singles: same-color static groups of 2+ weld
  (define ($sgl-weld! singles)
    (let part ((ns singles) (stat '()) (dyn '()))
      (if (pair? ns)
          (if ($sgl-static? (car ns))
              (part (cdr ns) (cons (car ns) stat) dyn)
              (part (cdr ns) stat (cons (car ns) dyn)))
          (let group ((ns (reverse stat)) (groups '()) (out (reverse dyn)))
            (if (null? ns)
                (append
                 (fold-left
                  (lambda (acc g)
                    (let ((members (cdr g)))
                      (if (and (pair? (cdr members))
                               (< (fold-left
                                   (lambda (a nd)
                                     (+ a (quotient
                                           (vector-ref
                                            ($sgl-nd-geo nd) 4)
                                           24)))
                                   0 members)
                                  65536))
                          (cons ($sgl-weld (reverse members)) acc)
                          (append (reverse members) acc))))
                  '() groups)
                 out)
                (let* ((f ($sgl-nd-f (car ns)))
                       (key (list (vector-ref f 7) (vector-ref f 8)
                                  (vector-ref f 9) (vector-ref f 10)))
                       (hit (assoc key groups)))
                  (if hit
                      (begin (set-cdr! hit (cons (car ns) (cdr hit)))
                             (group (cdr ns) groups out))
                      (group (cdr ns)
                             (cons (cons key (list (car ns))) groups)
                             out))))))))

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
              (begin
                ;; every grouped node gets its staging cache home
                (for-each (lambda (nd)
                            ($sgl-nd-cbase! nd (fx-alloc! 80)))
                          mine)
                (outer (cdr ns) (cons g grouped)
                       ;; slots 5-7 cache the last frame's camera
                       ;; signature, transform generation and visible
                       ;; count, so a static group under a still camera
                       ;; redraws without re-culling or re-uploading
                       (cons (vector g mine (fx-buffer!)
                                     (fx-alloc! (* (length mine) 80))
                                     (length mine) -1.0 -1 -1)
                             groups)
                       singles))))))))

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

  ;; the chain fold and TRS rebuild happen only when a signal
  ;; moved something -- a static node composes exactly once
  (define ($sgl-refresh! nd)
    (let ((f ($sgl-nd-f nd))
          (gen ($sgl-node-gen nd)))
      (unless (and (= gen ($sgl-nd-cgen nd)) ($sgl-nd-cmodel nd))
        ($sgl-nd-cmodel!
         nd (m4-mul (fold-left (lambda (acc gf)
                                 (m4-mul acc ($sgl-trs gf)))
                               (m4-identity) ($sgl-nd-chain nd))
                    ($sgl-trs f)))
        ($sgl-nd-cscale!
         nd (fold-left (lambda (acc gf) (fl* acc (vector-ref gf 6)))
                       (vector-ref f 6) ($sgl-nd-chain nd)))
        ($sgl-nd-cgen! nd gen))))

  (define ($sgl-draw-node*! prog vp planes nd)
    ($sgl-refresh! nd)
    (let ((f ($sgl-nd-f nd))
          (geo ($sgl-nd-geo nd))
          (model ($sgl-nd-cmodel nd))
          (s ($sgl-nd-cscale nd)))
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
  (define ($sgl-draw-igroup! prog ig planes scratch camsig)
    (let* ((geo (vector-ref ig 0))
           (ibuf (vector-ref ig 2))
           (ibase (vector-ref ig 3))
           (soa (+ scratch 256))
           (ctr (+ scratch 320))
           (ones (+ scratch 336))
           (res (+ scratch 352))
           ;; the group's transform generation: the sum moves iff any
           ;; instance's own or ancestor transform did
           (gen (fold-left (lambda (a nd) (+ a ($sgl-node-gen nd)))
                           0 (vector-ref ig 1)))
           ;; issue the draw; upload the packed instances only when the
           ;; set was recomputed (up? = #t), else the buffer still holds
           ;; last frame's identical data
           (draw!
            (lambda (n up?)
              (when up? (vector-set! ig 7 n))
              (when (> n 0)
                (fx-use-instanced! prog ($sgl-geo-vbuf geo) ibuf)
                ($sgl-geo-upload! geo)
                (cmd-bind-index! ($sgl-geo-ibuf geo))
                (cmd-bind-buffer! ibuf)
                (when up? (cmd-buffer-data! ibase (* n 80)))
                (cmd-draw-elements-instanced!
                 GL-TRIANGLES ($sgl-geo-icount geo) n)))))
      (if (and (fl=? camsig (vector-ref ig 5))
               (= gen (vector-ref ig 6))
               (>= (vector-ref ig 7) 0))
          ;; nothing moved and the frustum held: redraw the cached set
          (draw! (vector-ref ig 7) #f)
          (begin
            (vector-set! ig 5 camsig)
            (vector-set! ig 6 gen)
            (%sgl-igroup-fill! ig planes scratch soa ctr ones res draw!))))
    #t)

  (define (%sgl-igroup-fill! ig planes scratch soa ctr ones res flush!)
    (let ((ibase (vector-ref ig 3)))
      (let fill ((ns (vector-ref ig 1)) (n 0))
        (let gather ((ns ns) (m 0))     ; next four lod-active nodes
          (if (and (pair? ns) (< m 4))
              (if ($sgl-lod-active? (car ns))
                  (begin (vector-set! $sgl-chunk m (car ns))
                         (gather (cdr ns) (+ m 1)))
                  (gather (cdr ns) m))
              (if (= m 0)
                  (flush! n #t)
                  (begin
                    ;; refresh each node's cache when its generation
                    ;; moved (matrix, then the center as the cached
                    ;; columns recombined in SIMD, then the radius);
                    ;; a static node did all this exactly once
                    (let comp ((k 0))
                      (when (< k m)
                        (let* ((nd (vector-ref $sgl-chunk k))
                               (f ($sgl-nd-f nd))
                               (bc ($sgl-nd-bc nd))
                               (cb ($sgl-nd-cbase nd))
                               (gen ($sgl-node-gen nd)))
                          (unless (= gen ($sgl-nd-cgen nd))
                            ($sgl-model-into! nd cb scratch)
                            (%f32x4-scale! ctr cb (v3-x bc))
                            (%f32x4-axpy! ctr ctr (+ cb 16) (v3-y bc))
                            (%f32x4-axpy! ctr ctr (+ cb 32) (v3-z bc))
                            (%f32x4-axpy! ctr ctr (+ cb 48) 1.0)
                            (%mem-f32-set! (+ cb 64) (%mem-f32-ref ctr))
                            (%mem-f32-set! (+ cb 68)
                                           (%mem-f32-ref (+ ctr 4)))
                            (%mem-f32-set! (+ cb 72)
                                           (%mem-f32-ref (+ ctr 8)))
                            (%mem-f32-set!
                             (+ cb 76)
                             (fl* (fold-left
                                   (lambda (acc gf)
                                     (fl* acc (vector-ref gf 6)))
                                   (vector-ref f 6)
                                   ($sgl-nd-chain nd))
                                  ($sgl-nd-br nd)))
                            ($sgl-nd-cgen! nd gen))
                          ;; the cull's SoA reads straight off caches
                          (%mem-f32-set! (+ soa (* k 4))
                                         (%mem-f32-ref (+ cb 64)))
                          (%mem-f32-set! (+ (+ soa 16) (* k 4))
                                         (%mem-f32-ref (+ cb 68)))
                          (%mem-f32-set! (+ (+ soa 32) (* k 4))
                                         (%mem-f32-ref (+ cb 72)))
                          (%mem-f32-set! (+ (+ soa 48) (* k 4))
                                         (%mem-f32-ref (+ cb 76))))
                        (comp (+ k 1))))
                    ($sgl-cull4! planes soa ones res m)
                    ;; visible ones copy cache -> next buffer slot
                    (let pack ((k 0) (n2 n))
                      (if (= k m)
                          (if (pair? ns)
                              (fill ns n2)
                              (flush! n2 #t))
                          (if (vector-ref $sgl-vis k)
                              (let* ((nd (vector-ref $sgl-chunk k))
                                     (f ($sgl-nd-f nd))
                                     (dst (+ ibase (* n2 80))))
                                ($sgl-m4s-copy!
                                 dst ($sgl-nd-cbase nd))
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
           ;; a cheap frustum signature: the camera fields and aspect
           ;; weighted-summed.  Unchanged frame to frame => the frustum
           ;; held, so static instanced groups need no re-cull/upload
           (camsig (let loop ((i 0) (acc (fl* aspect 1000003.0)))
                     (if (= i 9) acc
                         (loop (+ i 1)
                               (fl+ acc (fl* ($sgl-fl (vector-ref cam i))
                                             (fixnum->flonum
                                              (+ 3 (* i 7)))))))))
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
      ;; the frame globals ship once: vp, light direction, ambient
      ;; and eye lay out std140 in staging and one cmd-ubo-data!
      ;; carries them; every program reads binding 0
      (let ((ea ($sgl-envat sc)))
        (m4s-write! ea vp)
        (%mem-f32-set! (+ ea 64) (v3-x ld))
        (%mem-f32-set! (+ ea 68) (v3-y ld))
        (%mem-f32-set! (+ ea 72) (v3-z ld))
        (%mem-f32-set! (+ ea 76) (vector-ref light 3))
        (%mem-f32-set! (+ ea 80) (v3-x eye))
        (%mem-f32-set! (+ ea 84) (v3-y eye))
        (%mem-f32-set! (+ ea 88) (v3-z eye))
        (cmd-ubo-data! ($sgl-env sc) ea 96)
        (cmd-bind-ubo! 0 ($sgl-env sc)))
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
      ;; instanced groups first: one draw per shared geometry.
      ;; the light, ambient and vp all ride the Env block now
      (when ($sgl-iprog sc)
        (let ((p ($sgl-iprog sc)))
          (cmd-use-program! (fx-program-slot p))
          (for-each (lambda (ig)
                      ($sgl-draw-igroup! p ig planes
                                         ($sgl-iscratch sc) camsig))
                    ($sgl-igroups sc))))
      ;; opaque singles first (front to back), collecting any
      ;; translucent ones (color alpha < 1) into tr for the blended
      ;; pass that follows
      (let ((tr (list '())))
        ($sgl-group! ($sgl-prog sc) ($sgl-lits sc) vp planes eye
                     (lambda (p) #f) tr)
        ($sgl-group! ($sgl-tprog sc) ($sgl-texs sc) vp planes eye
                     (lambda (p)
                       (fx-uniform! p 'u_tex 0)) tr)
        ($sgl-group! ($sgl-pprog sc) ($sgl-pbrs sc) vp planes eye
                     (lambda (p)
                       (let ((probe ($sgl-probe sc)))
                         (cmd-bind-cubemap! 0 (vector-ref probe 0))
                         (cmd-bind-texture! 1 (vector-ref probe 1))
                         (fx-uniform! p 'u_sky 0)
                         (fx-uniform! p 'u_lut 1)
                         (fx-uniform! p 'u_mips (vector-ref probe 2))))
                     tr)
        ;; the translucent pass: farthest first, blend on, depth
        ;; writes off (they test against the opaque depth but do not
        ;; occlude each other), each node with its own program
        (when (pair? (car tr))
          (cmd-blend! 'alpha)
          (cmd-depth-write! #f)
          (for-each
           (lambda (item)              ; item = (-dist . (prog setup . nd))
             (let ((e (cdr item)))     ; e = (prog setup . nd)
               (cmd-use-program! (fx-program-slot (car e)))
               ((cadr e) (car e))
               ($sgl-draw-node*! (car e) vp planes (cddr e))))
           ;; farthest first: the ascending merge sort on a negated
           ;; distance key
           ($sgl-sort (map (lambda (e)
                             (cons (fl- 0.0 (car e)) (cdr e)))
                           (car tr))))
          (cmd-depth-write! #t)
          (cmd-blend! 'off)))))

  ;; merge sort by an flonum key -- the frame's draw-order sort
  (define ($sgl-sort ks)                ; ks: ((key . nd) ...)
    (if (or (null? ks) (null? (cdr ks)))
        ks
        (let split ((slow ks) (fast ks) (left '()))
          (if (or (null? fast) (null? (cdr fast)))
              (let merge ((a ($sgl-sort (reverse left)))
                          (b ($sgl-sort slow))
                          (out '()))
                (cond
                 ((null? a) (append (reverse out) b))
                 ((null? b) (append (reverse out) a))
                 ((fl<? (car (car a)) (car (car b)))
                  (merge (cdr a) b (cons (car a) out)))
                 (else (merge a (cdr b) (cons (car b) out)))))
              (split (cdr slow) (cddr fast) (cons (car slow) left))))))

  ;; one material's pass: the shared uniforms once, then each node
  ;; nearest first -- opaque geometry drawn front to back hands the
  ;; depth test the whole occluded fragment bill (early z).  The tex
  ;; pass keys on the texture slot first, so equal textures bind
  ;; once, nearest first within each
  ;; a node with color alpha below one is translucent: it skips the
  ;; opaque pass and joins tr (tagged with this program and setup)
  ;; for the later back-to-front blended pass
  (define ($sgl-nd-alpha nd) (vector-ref ($sgl-nd-f nd) 10))

  (define ($sgl-group! prog nodes vp planes eye setup! tr)
    (when (pair? nodes)
      (cmd-use-program! (fx-program-slot prog))
      (setup! prog)
      (let ((ex (v3-x eye)) (ey (v3-y eye)) (ez (v3-z eye)))
        (for-each
         (lambda (k) ($sgl-draw-node*! prog vp planes (cdr k)))
         ($sgl-sort
          (fold-left
           (lambda (acc nd)
             (if ($sgl-lod-active? nd)
                 (begin
                   ($sgl-refresh! nd)
                   (let* ((m ($sgl-nd-cmodel nd))
                          (dx (fl- (vector-ref m 12) ex))
                          (dy (fl- (vector-ref m 13) ey))
                          (dz (fl- (vector-ref m 14) ez))
                          (d2 (fl+ (fl* dx dx)
                                   (fl+ (fl* dy dy) (fl* dz dz))))
                          (tx ($sgl-nd-tex nd)))
                     (if (fl<? ($sgl-nd-alpha nd) 1.0)
                         ;; defer: (dist prog setup . nd)
                         (begin
                           (set-car! tr
                                     (cons (cons d2 (cons prog
                                                          (cons setup! nd)))
                                           (car tr)))
                           acc)
                         (cons (cons (if tx
                                         ;; texture major, distance minor
                                         (fl+ (fl* 1000000000.0
                                                   (fixnum->flonum tx))
                                              d2)
                                         d2)
                                     nd)
                               acc))))
                 acc))
           '() nodes)))))))
