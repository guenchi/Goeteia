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
;; is built and uploaded once ((web mesh) generates it, the first
;; draw ships it), and each unquoted attribute becomes a hole whose
;; effect copies the signal's value into the node -- so a frame is
;; pure arithmetic over current fields, and only changed values move.
;;
;; Tags: (camera (@ (fov f) (near n) (far f) (position x y z)
;;                  (look-at x y z)))
;;       (light (@ (direction x y z) (ambient a)))
;;       (probe (@ (sky slot) (lut slot) (mips m)))  -- the (web ibl)
;;         pair the scene's pbr meshes reflect; slots may be unquotes,
;;         evaluated once
;;       (mesh (@ (geometry SPEC) attrs...))
;; Geometry specs: (plane w d) (box w h d) (sphere r [segs rings])
;;       (cylinder r h [segs]) (torus R r [segs rings]), or a lone
;;       unquote yielding a (web mesh) mesh, injected once.
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
(library (web scene)
  (export sgl $sgl-build sgl-scene? sgl-draw!)
  (import (rnrs) (web js) (web gl) (web glsl) (web fx) (web mat)
          (web mesh) (web reactive))

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
                   (let ((tag (car f)) (rest (cdr f)))
                     (if (and (pair? rest) (pair? (car rest))
                              (eq? (car (car rest)) '@))
                         (list tag (cons '@ (map walk-attr (cdr (car rest)))))
                         f)))))
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
            (immutable probe $sgl-probe)   ; (sky lut mips) | #f
            (immutable cam $sgl-cam)     ; fov near far px py pz lx ly lz
            (immutable light $sgl-light) ; dx dy dz ambient
            (immutable lits $sgl-lits)   ; nodes, split by material
            (immutable texs $sgl-texs)
            (immutable pbrs $sgl-pbrs)))

  (define-record-type ($sgl-node $make-sgl-node $sgl-node?)
    (fields (immutable vbuf $sgl-nd-vbuf)
            (immutable ibuf $sgl-nd-ibuf)
            (immutable vbase $sgl-nd-vbase)
            (immutable ibase $sgl-nd-ibase)
            (immutable vbytes $sgl-nd-vbytes)
            (immutable ibytes $sgl-nd-ibytes)
            (immutable icount $sgl-nd-icount)
            (mutable up? $sgl-nd-up? $sgl-nd-up!)
            ;; px py pz rx ry rz scale r g b a metallic roughness
            (immutable f $sgl-nd-f)
            (immutable mat $sgl-nd-mat)  ; lit | tex | pbr
            (immutable tex $sgl-nd-tex)  ; texture slot | #f
            (immutable bc $sgl-nd-bc)    ; bounding sphere, local
            (immutable br $sgl-nd-br)))

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

  (define ($sgl-mesh attrs ds)
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
      (let* ((geom ($sgl-geometry gspec ds))
             (uv? (eq? mat 'tex))       ; tex material samples uvs
             (vbytes (if uv?
                         (mesh-vertex-bytes-uv geom)
                         (mesh-vertex-bytes geom)))
             (bounds (mesh-bounds geom))
             (vbuf (fx-buffer!))
             (ibuf (fx-buffer!))
             (vbase (fx-alloc! vbytes))
             (ibase (fx-alloc! (mesh-index-bytes geom))))
        (if uv?
            (mesh-write-uv! geom vbase ibase)
            (mesh-write! geom vbase ibase))
        ($make-sgl-node vbuf ibuf vbase ibase
                        vbytes (mesh-index-bytes geom)
                        (mesh-index-count geom) #f f mat tex
                        (car bounds) (cdr bounds)))))

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
          (meshes '()))
      (for-each
       (lambda (f)
         (let ((attrs (if (and (pair? (cdr f)) (pair? (cadr f))
                               (eq? (car (cadr f)) '@))
                          (cdr (cadr f))
                          '())))
           (case (car f)
             ((camera) ($sgl-cam! cam attrs ds))
             ((light) ($sgl-light! light attrs ds))
             ((probe) (set! probe ($sgl-probe! attrs ds)))
             ((mesh) (set! meshes (cons ($sgl-mesh attrs ds) meshes)))
             (else (error 'sgl "unknown tag" (car f))))))
       forms)
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
              ($make-sgl
               (and (pair? lits) (fx-program! mesh-lit-vs mesh-lit-fs))
               (and (pair? texs) (fx-program! mesh-tex-vs mesh-tex-fs))
               (and (pair? pbrs) (fx-program! mesh-pbr-vs mesh-pbr-fs))
               probe cam light
               (reverse lits) (reverse texs) (reverse pbrs)))))))

  ;; ---- a frame: pure arithmetic over the current fields ----
  ;; The model matrix places the node's bounding sphere; a node the
  ;; frustum cannot see costs exactly this arithmetic and no commands.
  (define ($sgl-draw-node! prog vp planes nd)
    (let* ((f ($sgl-nd-f nd))
           (s (vector-ref f 6))
           (model
            (m4-mul (m4-translate (vector-ref f 0) (vector-ref f 1)
                                  (vector-ref f 2))
                    (m4-mul (m4-rotate-y (vector-ref f 4))
                            (m4-mul (m4-rotate-x (vector-ref f 3))
                                    (m4-mul (m4-rotate-z (vector-ref f 5))
                                            (m4-scale s s s)))))))
      (when (sphere-in-frustum? planes
                                (m4-transform model ($sgl-nd-bc nd))
                                (fl* s ($sgl-nd-br nd)))
        (fx-use! prog ($sgl-nd-vbuf nd))
        (cmd-bind-index! ($sgl-nd-ibuf nd))
        (unless ($sgl-nd-up? nd)        ; geometry ships on first draw
          (cmd-buffer-data! ($sgl-nd-vbase nd) ($sgl-nd-vbytes nd))
          (cmd-index-data! ($sgl-nd-ibase nd) ($sgl-nd-ibytes nd))
          ($sgl-nd-up! nd #t))
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
        (cmd-draw-elements! GL-TRIANGLES ($sgl-nd-icount nd)))))

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
