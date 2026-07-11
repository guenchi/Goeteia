;; expect: #t
;; (web three) against a mock THREE: the s3d template builds the scene
;; graph once through the FFI, holes update via effects, and the
;; requestAnimationFrame pump drives Scheme once per frame.
(import (web reactive) (web three) (web js))

(js-eval "globalThis.THREE = (() => { const v3 = () => ({x:0,y:0,z:0}); const base = t => ({ type:t, children:[], position:v3(), rotation:v3(), scale:{x:1,y:1,z:1}, add(c){ this.children.push(c) } }); return { Scene: function(){ Object.assign(this, base('Scene')) }, Group: function(){ Object.assign(this, base('Group')) }, Mesh: function(g,m){ Object.assign(this, base('Mesh')); this.geometry=g; this.material=m }, PerspectiveCamera: function(fov,aspect,near,far){ Object.assign(this, base('Camera')); this.fov=fov; this.aspect=aspect }, AmbientLight: function(c,i){ Object.assign(this, base('AmbientLight')); this.color=c; this.intensity=i }, DirectionalLight: function(c,i){ Object.assign(this, base('DirectionalLight')); this.color=c; this.intensity=i }, PointLight: function(c,i){ Object.assign(this, base('PointLight')); this.intensity=i }, BoxGeometry: function(...a){ this.gtype='Box'; this.args=a }, SphereGeometry: function(...a){ this.gtype='Sphere'; this.args=a }, MeshBasicMaterial: function(p){ this.mtype='Basic'; this.params=p }, MeshStandardMaterial: function(p){ this.mtype='Standard'; this.params=p }, MeshNormalMaterial: function(p){ this.mtype='Normal'; this.params=p }, WebGLRenderer: function(p){ this.renders=0; this.domElement={tag:'canvas'}; this.setSize=(w,h)=>{ this.w=w; this.h=h }; this.render=(s,c)=>{ this.renders++ } } } })()")

;; js->number returns a fixnum for integral values, so compare generically
(define (near? v x) (and (< (- x 0.001) v) (< v (+ x 0.001))))
(define (num obj . path)
  (let loop ((o obj) (p path))
    (if (null? (cdr p))
        (js->number (js-get o (car p)))
        (loop (js-get o (car p)) (cdr p)))))

;;; the scene: static structure + two holes
(define angle (signal 0.0))
(define sc
  (s3d (scene
         (mesh (@ (geometry (box 1 2 3))
                  (material (basic (@ (color "#ff0000"))))
                  (position 0 1 0)
                  (rotation-y ,(signal-ref angle))))
         (group
           (mesh (@ (geometry (sphere 2)) (material (normal))
                    (scale 2 2 2))))
         (ambient-light (@ (intensity 0.5)))
         (directional-light (@ (position 5 10 7) (intensity 1.2))))))

(define kids (js-get sc "children"))
(define mesh1 (js-index kids 0))
(define grp (js-index kids 1))
(define amb (js-index kids 2))
(define dir (js-index kids 3))

(define built-ok
  (and (string=? (js->string (js-get sc "type")) "Scene")
       (= (js->number (js-get kids "length")) 4)
       ;; geometry spec -> constructor args
       (string=? (js->string (js-get (js-get mesh1 "geometry") "gtype")) "Box")
       (= (num (js-get mesh1 "geometry") "args" "1") 2)
       ;; material params object
       (string=? (js->string (js-get (js-get (js-get mesh1 "material") "params") "color"))
                 "#ff0000")
       ;; multi-value and nested attributes
       (= (num mesh1 "position" "y") 1)
       (= (num grp "children" "length") 1)
       (= (num (js-index (js-get grp "children") 0) "scale" "z") 2)
       ;; light constructor attrs
       (near? (num amb "intensity") 0.5)
       (near? (num dir "intensity") 1.2)
       (= (num dir "position" "x") 5)))

;;; holes: a signal write crosses the bridge, nothing else does
(define hole-ok-1 (near? (num mesh1 "rotation" "y") 0.0))
(signal-set! angle 0.7)
(define hole-ok-2 (near? (num mesh1 "rotation" "y") 0.7))

;;; camera: constructor attrs consumed, not re-applied
(define cam (s3d (perspective-camera (@ (fov 60) (position 0 1 3)))))
(define cam-ok
  (and (= (num cam "fov") 60)
       (= (num cam "position" "z") 3)))

;;; renderer + frame pump (mock requestAnimationFrame, stepped by hand)
(js-eval "globalThis.__frames = []; globalThis.requestAnimationFrame = f => { globalThis.__frames.push(f); return globalThis.__frames.length }")
(js-eval "globalThis.__stage = { appendChild(c){ this.canvas = c } }")
(define renderer (three-renderer (js-get (js-global) "__stage") 640 480))
(define frames 0)
(three-loop!
 (lambda ()
   (set! frames (+ frames 1))
   (three-render! renderer sc cam)))
(define (pump!)
  (let* ((fr (js-get (js-global) "__frames"))
         (n (js->number (js-get fr "length"))))
    (js-call (js-index fr (- n 1)) (js-undefined))))
(pump!)
(pump!)
(define loop-ok
  (and (= frames 2)
       (= (num renderer "renders") 2)
       (= (num renderer "w") 640)
       (string=? (js->string (js-get (js-get (js-get (js-global) "__stage") "canvas") "tag"))
                 "canvas")))

(and built-ok hole-ok-1 hole-ok-2 cam-ok loop-ok)
