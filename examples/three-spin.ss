;; A spinning cube -- a 3D scene authored in Goeteia over Three.js.
;; The scene graph is built once; only the two rotation holes update
;; per frame (a signal write each), everything else never crosses the
;; bridge again.
(import (web three) (web reactive) (web dom) (web js))

(define angle (signal 0.0))

(define world
  (s3d (scene
         (mesh (@ (geometry (box 1 1 1))
                  (material (standard (@ (color "#1550c4") (metalness 0.3) (roughness 0.35))))
                  (rotation-y ,(signal-ref angle))
                  (rotation-x ,(* 0.4 (signal-ref angle)))))
         (ambient-light (@ (intensity 0.6)))
         (directional-light (@ (intensity 1.6) (position 5 10 7))))))

(define camera
  (s3d (perspective-camera (@ (fov 60) (position 0 0.8 3)))))
(js-set! camera "aspect" (/ 640.0 480.0))
(js-method camera "updateProjectionMatrix")

(define renderer (three-renderer (get-element-by-id "app") 640 480))

(three-loop!
 (lambda ()
   (signal-update! angle (lambda (a) (+ a 0.02)))
   (three-render! renderer world camera)))

(console-log "3D scene mounted from Goeteia")
