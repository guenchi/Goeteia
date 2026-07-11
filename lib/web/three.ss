;; Reactive 3D scenes over Three.js -- the sx of the third dimension.
;;
;;   (s3d (scene
;;          (mesh (@ (geometry (box 1 1 1))
;;                   (material (standard (@ (color "#1550c4"))))
;;                   (rotation-y ,(signal-ref angle))))
;;          (ambient-light (@ (intensity 0.6)))
;;          (directional-light (@ (intensity 1.2) (position 5 10 7)))))
;;
;; The template splits at expansion time: the static scene graph is
;; built once through the FFI (THREE must be on globalThis -- load it
;; with a script tag or import map); each unquoted attribute value
;; becomes a hole updated by its own effect, so bridge traffic is
;; O(changes), not O(frames). Continuous motion drives a signal from
;; three-loop! (a requestAnimationFrame pump into Scheme).
;;
;; Tags: scene group mesh perspective-camera ambient-light
;;       directional-light point-light
;; Geometry specs: (box w h d) (sphere r ...) (plane w h)
;;       (cylinder ...) (torus ...) (cone ...) or a raw js-ref
;; Material specs: (basic|standard|phong|lambert|normal (@ (k v) ...))
;;       or a raw js-ref
;; Attributes: (position x y z) (rotation x y z) (scale x y z),
;;       single-axis position-x/-y/-z rotation-* scale-*, and any
;;       plain JS property name (intensity, visible, fov, ...).
;;       Constructor attributes (geometry/material, a camera's
;;       fov/aspect/near/far, a light's color/intensity) are static;
;;       holes go in the others. A child-position unquote injects an
;;       already-built object once (no reactive add/remove yet).
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web three)
  (export s3d $s3d-build three-ref
          three-renderer three-render! three-loop!)
  (import (rnrs) (web js) (web reactive))

  ;; ---- the template macro: same architecture as sx ----
  (define-syntax s3d
    (lambda (x)
      (syntax-case x ()
        ((_ tmpl)
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
                   (cons '$s3d-d (- nd 1))))
                (walk-attr
                 (lambda (a)
                   ;; only a lone top-level unquote value becomes a hole
                   (if (and (pair? (cdr a)) (unq? (cadr a)) (null? (cddr a)))
                       (list (car a) (add-thunk! (cadr (cadr a))))
                       a)))
                (walk
                 (lambda (t)
                   (cond
                    ((unq? t) (add-thunk! (cadr t)))   ; child: injected once
                    ((pair? t)
                     (let ((tag (car t)) (rest (cdr t)))
                       (if (and (pair? rest) (pair? (car rest))
                                (eq? (car (car rest)) '@))
                           (cons tag
                                 (cons (cons '@ (map walk-attr (cdr (car rest))))
                                       (map walk (cdr rest))))
                           (cons tag (map walk rest)))))
                    (else t)))))
             (let ((anno (walk tmpl)))
               (list '$s3d-build (list 'quote anno)
                     (cons 'list (reverse thunks))))))))))

  (define ($s3d-d? t) (and (pair? t) (eq? (car t) '$s3d-d)))

  (define (three-ref name)
    (js-get (js-get (js-global) "THREE") name))

  ;; ---- constructors ----
  (define (attr-default attrs name d)
    (let ((a (assq name attrs))) (if a (cadr a) d)))

  (define ($s3d-geometry spec)
    (if (js-ref? spec)
        spec
        (apply js-new
               (three-ref
                (case (car spec)
                  ((box) "BoxGeometry") ((sphere) "SphereGeometry")
                  ((plane) "PlaneGeometry") ((cylinder) "CylinderGeometry")
                  ((torus) "TorusGeometry") ((cone) "ConeGeometry")
                  (else (error 's3d "unknown geometry" (car spec)))))
               (cdr spec))))

  (define ($s3d-material spec)
    (if (js-ref? spec)
        spec
        (let* ((attrs (if (and (pair? (cdr spec)) (pair? (cadr spec))
                               (eq? (car (cadr spec)) '@))
                          (cdr (cadr spec))
                          '()))
               (params (js-eval "({})")))
          (for-each (lambda (a)
                      (js-set! params (symbol->string (car a)) (cadr a)))
                    attrs)
          (js-new (three-ref
                   (case (car spec)
                     ((basic) "MeshBasicMaterial")
                     ((standard) "MeshStandardMaterial")
                     ((phong) "MeshPhongMaterial")
                     ((lambert) "MeshLambertMaterial")
                     ((normal) "MeshNormalMaterial")
                     (else (error 's3d "unknown material" (car spec)))))
                  params))))

  (define ($s3d-make tag attrs)
    (case tag
      ((scene) (js-new (three-ref "Scene")))
      ((group) (js-new (three-ref "Group")))
      ((mesh)
       (js-new (three-ref "Mesh")
               ($s3d-geometry (attr-default attrs 'geometry #f))
               ($s3d-material (attr-default attrs 'material '(normal)))))
      ((perspective-camera)
       (js-new (three-ref "PerspectiveCamera")
               (attr-default attrs 'fov 75)
               (attr-default attrs 'aspect 1)
               (attr-default attrs 'near 0.1)
               (attr-default attrs 'far 1000)))
      ((ambient-light)
       (js-new (three-ref "AmbientLight")
               (attr-default attrs 'color "#ffffff")
               (attr-default attrs 'intensity 1)))
      ((directional-light)
       (js-new (three-ref "DirectionalLight")
               (attr-default attrs 'color "#ffffff")
               (attr-default attrs 'intensity 1)))
      ((point-light)
       (js-new (three-ref "PointLight")
               (attr-default attrs 'color "#ffffff")
               (attr-default attrs 'intensity 1)))
      (else (error 's3d "unknown tag" tag))))

  ;; attributes consumed by the constructor: never re-applied, no holes
  (define ($s3d-consumed tag)
    (case tag
      ((mesh) '(geometry material))
      ((perspective-camera) '(fov aspect near far))
      ((ambient-light directional-light point-light) '(color intensity))
      (else '())))

  ;; ---- attribute application ----
  ;; single-axis shorthands: (rotation-y v) sets obj.rotation.y
  (define $axis-attrs
    '((position-x "position" "x") (position-y "position" "y") (position-z "position" "z")
      (rotation-x "rotation" "x") (rotation-y "rotation" "y") (rotation-z "rotation" "z")
      (scale-x "scale" "x") (scale-y "scale" "y") (scale-z "scale" "z")))

  (define ($s3d-set obj name v)
    (let ((axis (assq name $axis-attrs)))
      (if axis
          (js-set! (js-get obj (cadr axis)) (caddr axis) v)
          (js-set! obj (symbol->string name) v))))

  (define ($s3d-attr obj name vals ds)
    (let ((v (car vals)))
      (cond
       (($s3d-d? v)                       ; a hole: its own effect
        (let ((th (list-ref ds (cdr v))))
          (effect (lambda () ($s3d-set obj name (th))))))
       ((memq name '(position rotation scale))
        (let ((t (js-get obj (symbol->string name))))
          (js-set! t "x" (car vals))
          (js-set! t "y" (cadr vals))
          (js-set! t "z" (caddr vals))))
       (else ($s3d-set obj name v)))))

  ;; ---- the builder ----
  (define ($s3d-build t ds)
    (if ($s3d-d? t)
        ((list-ref ds (cdr t)))            ; injected child, evaluated once
        (let* ((tag (car t))
               (rest (cdr t))
               (has-attrs (and (pair? rest) (pair? (car rest))
                               (eq? (car (car rest)) '@)))
               (attrs (if has-attrs (cdr (car rest)) '()))
               (kids (if has-attrs (cdr rest) rest))
               (obj ($s3d-make tag attrs))
               (consumed ($s3d-consumed tag)))
          (for-each (lambda (a)
                      (unless (memq (car a) consumed)
                        ($s3d-attr obj (car a) (cdr a) ds)))
                    attrs)
          (for-each (lambda (k)
                      (js-method obj "add" ($s3d-build k ds)))
                    kids)
          obj)))

  ;; ---- renderer and frame pump ----
  (define (three-renderer parent width height)
    (let ((r (js-new (three-ref "WebGLRenderer")
                     (js-eval "({antialias:true})"))))
      (js-method r "setSize" width height)
      (js-method parent "appendChild" (js-get r "domElement"))
      r))

  (define (three-render! renderer scene camera)
    (js-method renderer "render" scene camera))

  ;; call f once per animation frame, forever
  (define (three-loop! f)
    (letrec ((tick (lambda _
                     (f)
                     (js-method (js-global) "requestAnimationFrame" tick))))
      (js-method (js-global) "requestAnimationFrame" tick))))
