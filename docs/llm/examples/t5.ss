;; T5 -- an articulated, animated scene: three meshes chained parent
;; to child, two sliders driving the two joints, the whole rig turning
;; on its own.  This file IS the browser half; it builds its controls
;; into <div id="app"> and draws into <canvas id="c">.
(import (rnrs) (web js) (web dom)
        (gfx gl) (gfx glsl) (gfx fx) (gfx mat) (gfx mesh))

(define app (get-element-by-id "app"))
(define (num v) (exact->inexact (js->number v)))
(define (rad d) (fl* d (fl/ 3.141592653589793 180.0)))

;; Plain mutable state read by the frame callback: the control writes,
;; the loop reads.  Event callbacks return (js-undefined).
(define $shoulder 20.0)
(define $elbow -40.0)

(define (joint lo hi start receive)
  (let ((s (create-element "input")))
    (set-attribute! s "type" "range")
    (set-attribute! s "min" lo)
    (set-attribute! s "max" hi)
    (set-attribute! s "step" "1")
    (set-attribute! s "value" start)
    (append-child! app s)
    (add-event-listener! s "input"
      (lambda (ev)
        (receive (num (js-get (js-get ev "target") "value")))
        (js-undefined)))
    s))

(joint "-90" "90" "20" (lambda (v) (set! $shoulder v)))
(joint "-120" "0" "-40" (lambda (v) (set! $elbow v)))

(fx-init! (get-element-by-id "c"))
(define prog (fx-program! mesh-lit-vs mesh-lit-fs))

;; one box two units tall, centred on the origin: its pivot is the
;; frame it is drawn in, so a limb translates its own half-length up
(define limb (fx-mesh! (mesh-box 0.44 2.0 0.44)))
(define plinth (fx-mesh! (mesh-box 1.6 0.4 1.6)))

(define proj (m4-perspective 0.9 (fl/ 800.0 600.0) 0.1 100.0))
(define light (v3-normalize (v3 0.45 0.75 0.5)))

(define (draw! h vp model r g b)
  (fx-mesh-use! prog h)
  (fx-uniform! prog 'u_mvp (m4-mul vp model))
  (fx-uniform! prog 'u_model model)
  (fx-uniform! prog 'u_light (v3-x light) (v3-y light) (v3-z light))
  (fx-uniform! prog 'u_color r g b 1.0)
  (fx-uniform! prog 'u_ambient 0.24)
  (fx-mesh-draw! h))

;; THE HIERARCHY.  (m4-mul a b) applies b FIRST, so a is the PARENT
;; frame and b the child's own transform, and a chain reads outermost
;; joint first.  Each frame here is "where my parent put me" times
;; "how I turn"; a limb's geometry then moves half its length up so
;; that the frame sits at its lower END rather than its middle.
(fx-loop!
 (lambda (t dt)
   (cmd-depth! #t)
   (cmd-clear! 0.03 0.04 0.08 1.0)
   (let* ((vp (m4-mul proj (m4-look-at (v3 0.0 2.2 8.5)
                                       (v3 0.0 1.8 0.0)
                                       (v3 0.0 1.0 0.0))))
          (world (m4-rotate-y (fl* 0.35 t)))            ; the rig turns
          (hip (m4-mul world (m4-translate 0.0 0.2 0.0)))
          (upper (m4-mul hip (m4-rotate-z (rad $shoulder))))
          ;; the elbow rides at the far end of the upper arm
          (fore (m4-mul (m4-mul upper (m4-translate 0.0 2.0 0.0))
                        (m4-rotate-z (rad $elbow)))))
     (draw! plinth (m4-mul vp world) (m4-translate 0.0 0.0 0.0)
            0.55 0.58 0.66)
     (draw! limb vp (m4-mul upper (m4-translate 0.0 1.0 0.0))
            0.85 0.55 0.25)
     (draw! limb vp (m4-mul fore (m4-translate 0.0 1.0 0.0))
            0.35 0.75 0.90))))
