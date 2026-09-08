;; Copyright 2026 guenchi
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;; Reads test/assets/p1.glb (a Blender export carrying every feature
;; the material model and re-export need) and prints one line per
;; fact; test/gltf-p1.mjs compares the lines with what an independent
;; parse of the same file's JSON chunk predicts.
(import (rnrs) (gfx fx) (gfx gltf) (web fs))
(define cap 65536)
(define base (fx-alloc! cap))
(define n (fs-slurp! "test/assets/p1.glb" base cap))
(define g (gltf-parse base n))
(define (show . xs) (for-each display xs) (newline))
;; a factor as a signed integer number of millionths (the printer shows
;; twelve significant digits, so a decimal face would not match the
;; exporter's repr); rounds half away from zero on either side
(define (millionths f)
  (let ((m (fl* 1000000.0 (if (fl<? f 0.0) (fl- 0.0 f) f))))
    (* (if (fl<? f 0.0) -1 1) (%fl->fx (fl+ m 0.5)))))
;; per-target presence as a string of 0/1: "11" = both targets carry it
(define (mask v nt)
  (let loop ((k 0) (acc ""))
    (if (= k nt) acc
        (loop (+ k 1) (string-append acc (if (and v (vector-ref v k)) "1" "0"))))))
(define (ref->string r)
  (if r
      (string-append (number->string (gtexref-texture r)) "/"
                     (number->string (gtexref-image r)) "/"
                     (number->string (gtexref-sampler r)) "/"
                     (number->string (gtexref-texcoord r)) "/"
                     ;; the factor as millionths, an integer: the printer
                     ;; shows twelve significant digits, so a decimal face
                     ;; would never match the exporter's repr
                     (number->string (millionths (gtexref-factor r))))
      "-"))
(show "images " (vector-length (gltf-images g)))
(show "textures " (vector-length (gltf-textures g)))
(show "samplers " (vector-length (gltf-samplers g)))
(show "skins " (vector-length (gltf-skins g)))
(show "anims " (vector-length (gltf-anims g)))
(show "cameras " (vector-length (gltf-cameras g)))
(show "prims " (length (gltf-prims g)))
(let loop ((ps (gltf-prims g)) (i 0))
  (unless (null? ps)
    (let ((p (car ps)))
      (show "prim " i " base=" (ref->string (gprim-base-tex p))
            " mr=" (ref->string (gprim-mr-tex p))
            " normal=" (ref->string (gprim-normal-tex p))
            " emissive=" (ref->string (gprim-emissive-tex p))
            " occlusion=" (ref->string (gprim-occlusion-tex p)))
      (let ((nt (if (gprim-morph p) (vector-length (vector-ref (gprim-morph p) 1)) 0)))
        (show "prim " i " layout=" (gprim-layout p) " skin=" (gprim-skin p)
              " targets=" nt
              " normals=" (mask (gprim-morph-normals p) nt)
              " tangents=" (mask (gprim-morph-tangents p) nt))))
    (loop (cdr ps) (+ i 1))))
