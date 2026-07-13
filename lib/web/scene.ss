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
;;       (mesh (@ (geometry SPEC) attrs...))
;; Geometry specs: (plane w d) (box w h d) (sphere r [segs rings])
;;       (cylinder r h [segs]) (torus R r [segs rings]), or a lone
;;       unquote yielding a (web mesh) mesh, injected once.
;; Mesh attributes: (position x y z) (rotation x y z) (color r g b [a])
;;       and the single-valued position-x/-y/-z rotation-* scale
;;       color-r/-g/-b/-a; holes go in single-valued attributes
;;       (and ambient, fov, near, far).
;;
;; Everything renders through mesh-lit-vs/-fs: one directional light,
;; an ambient floor, per-mesh solid color.
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
    (fields (immutable prog $sgl-prog)
            (immutable cam $sgl-cam)     ; fov near far px py pz lx ly lz
            (immutable light $sgl-light) ; dx dy dz ambient
            (immutable meshes $sgl-meshes)))

  (define-record-type ($sgl-node $make-sgl-node $sgl-node?)
    (fields (immutable vbuf $sgl-nd-vbuf)
            (immutable ibuf $sgl-nd-ibuf)
            (immutable vbase $sgl-nd-vbase)
            (immutable ibase $sgl-nd-ibase)
            (immutable vbytes $sgl-nd-vbytes)
            (immutable ibytes $sgl-nd-ibytes)
            (immutable icount $sgl-nd-icount)
            (mutable up? $sgl-nd-up? $sgl-nd-up!)
            ;; px py pz rx ry rz scale r g b a
            (immutable f $sgl-nd-f)))

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

  (define ($sgl-mesh attrs ds)
    (let ((geom #f)
          (f (vector 0.0 0.0 0.0 0.0 0.0 0.0 1.0 0.8 0.8 0.8 1.0)))
      (for-each
       (lambda (a)
         (case (car a)
           ((geometry) (set! geom ($sgl-geometry (cadr a) ds)))
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
      (unless geom (error 'sgl "mesh needs a geometry"))
      (let ((vbuf (fx-buffer!))
            (ibuf (fx-buffer!))
            (vbase (fx-alloc! (mesh-vertex-bytes geom)))
            (ibase (fx-alloc! (mesh-index-bytes geom))))
        (mesh-write! geom vbase ibase)
        ($make-sgl-node vbuf ibuf vbase ibase
                        (mesh-vertex-bytes geom) (mesh-index-bytes geom)
                        (mesh-index-count geom) #f f))))

  (define ($sgl-build forms ds)         ; needs fx-init! first
    (let ((prog (fx-program! mesh-lit-vs mesh-lit-fs))
          (cam (vector 0.9 0.1 100.0 0.0 2.0 8.0 0.0 0.0 0.0))
          (light (vector 0.5 0.8 0.4 0.25))
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
             ((mesh) (set! meshes (cons ($sgl-mesh attrs ds) meshes)))
             (else (error 'sgl "unknown tag" (car f))))))
       forms)
      ($make-sgl prog cam light (reverse meshes))))

  ;; ---- a frame: pure arithmetic over the current fields ----
  (define ($sgl-draw-node! prog vp nd)
    (fx-use! prog ($sgl-nd-vbuf nd))
    (cmd-bind-index! ($sgl-nd-ibuf nd))
    (unless ($sgl-nd-up? nd)            ; geometry ships on first draw
      (cmd-buffer-data! ($sgl-nd-vbase nd) ($sgl-nd-vbytes nd))
      (cmd-index-data! ($sgl-nd-ibase nd) ($sgl-nd-ibytes nd))
      ($sgl-nd-up! nd #t))
    (let* ((f ($sgl-nd-f nd))
           (s (vector-ref f 6))
           (model
            (m4-mul (m4-translate (vector-ref f 0) (vector-ref f 1)
                                  (vector-ref f 2))
                    (m4-mul (m4-rotate-y (vector-ref f 4))
                            (m4-mul (m4-rotate-x (vector-ref f 3))
                                    (m4-mul (m4-rotate-z (vector-ref f 5))
                                            (m4-scale s s s)))))))
      (fx-uniform! prog 'u_mvp (m4-mul vp model))
      (fx-uniform! prog 'u_model model)
      (fx-uniform! prog 'u_color (vector-ref f 7) (vector-ref f 8)
                   (vector-ref f 9) (vector-ref f 10))
      (cmd-draw-elements! GL-TRIANGLES ($sgl-nd-icount nd))))

  (define (sgl-draw! sc)
    (let* ((cam ($sgl-cam sc))
           (light ($sgl-light sc))
           (prog ($sgl-prog sc))
           (aspect (fl/ ($sgl-fl (fx-width)) ($sgl-fl (fx-height))))
           (vp (m4-mul
                (m4-perspective (vector-ref cam 0) aspect
                                (vector-ref cam 1) (vector-ref cam 2))
                (m4-look-at
                 (v3 (vector-ref cam 3) (vector-ref cam 4) (vector-ref cam 5))
                 (v3 (vector-ref cam 6) (vector-ref cam 7) (vector-ref cam 8))
                 (v3 0.0 1.0 0.0))))
           (ld (v3-normalize (v3 (vector-ref light 0) (vector-ref light 1)
                                 (vector-ref light 2)))))
      (cmd-depth! #t)
      (cmd-use-program! (fx-program-slot prog))
      (fx-uniform! prog 'u_light (v3-x ld) (v3-y ld) (v3-z ld))
      (fx-uniform! prog 'u_ambient (vector-ref light 3))
      (for-each (lambda (nd) ($sgl-draw-node! prog vp nd))
                ($sgl-meshes sc)))))
