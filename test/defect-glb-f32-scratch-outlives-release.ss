;; expect: #t
;; EXPECTED FAIL against lib/gfx/glb.ss at 61b4a3f.  $as-f32 takes a
;; four byte scratch word on first use and caches it in $f32-cell
;; FOREVER.  fx-release! is a bump reset -- (set! $fx-heap m) -- so an
;; allocation taken before a mark and kept across the release is handed
;; out again to the next caller, and $as-f32 then writes four bytes
;; into whatever now lives there.  Silent: no diagnostic, no trap, a
;; wrong value appears in somebody else's buffer.
;;
;; THE TREE ALREADY NAMES THIS HAZARD TWICE, and glb.ss does the thing
;; both notes warn about.  lib/gfx/fx.ss:160 -- "A mark taken before an
;; allocation that outlives the release is a use-after-free with no
;; diagnostic."  lib/gfx/gltf.ss:1590, giving it as the REASON the CPU
;; skinning scratch is allocated from the asset's own arena -- "a
;; lazily grabbed static would outlive an fx-release! and hand the
;; kernel somebody else's bytes."  $f32-cell is a lazily grabbed
;; static.
;;
;; The comment on $as-f32 argues the other horn, and the argument is
;; real: "the heap is not ours to claim from before a caller has asked
;; for anything" is a true objection to allocating at load time.  The
;; answer the tree already gives is neither horn -- give the scratch a
;; lifetime that MATCHES ITS USE.  fx-mark is exported, so the cached
;; word can check whether the water level has dropped to or below it
;; and take a fresh one when it has.
;;
;; Measured on this fixture: 4 bytes of a 1460 byte victim allocation.
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx gltf) (gfx glb) (web json))
(js-eval "globalThis.__mockcanvas = { width:64, height:64, addEventListener(k,f){}, getContext(kind) { return { createShader(){return {}}, shaderSource(){}, compileShader(){}, getShaderParameter(){return true}, createProgram(){return {}}, attachShader(){}, linkProgram(){}, getProgramParameter(){return true}, bindAttribLocation(){}, getUniformLocation(){return {}}, createBuffer(){return {}}, createVertexArray(){return {}}, createTexture(){return {}}, viewport(){}, enable(){}, clearColor(){}, clear(){} } } }")
(fx-init! (js-get (js-global) "__mockcanvas"))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))

(define layout '(position normal uv))
(define stride (glb-stride layout))
(define vcount 3)
(define vbase (fx-alloc! (* vcount stride)))
(define ibase (fx-alloc! 8))
(define nodes (list (list "root" -1 (vector 0.0 0.0 0.0) (vector 0.0 0.0 0.0 1.0) (vector 1.0 1.0 1.0))))
;; two keyframes, because the ordering guard is what reaches $as-f32
;; before the bounds are narrowed as well
(define (export!)
  (glb-write! (list (list layout vbase vcount ibase 3))
              'nodes nodes
              'anims (list (list "a" (list (list 0 'translation (vector 0.0 1.0)
                                                 (vector (vector 0.0 0.0 0.0) (vector 2.0 0.0 0.0))
                                                 2 'linear))))))
(define (fill! at n b)
  (let f ((i 0)) (when (< i n) (%mem-u8-set! (+ at i) b) (f (+ i 1)))))
(define (dirt at n b)
  (let c ((i 0) (n2 0))
    (if (>= i n) n2 (c (+ i 1) (if (= (%mem-u8-ref (+ at i)) b) n2 (+ n2 1))))))

;; an export, a release back to the mark taken before it, then somebody
;; else allocating the reclaimed span -- the ordinary shape of exporting
;; one asset, tearing it down, and building the next
(define m0 (fx-mark))
(export!)
(define span (- (fx-mark) m0))
(fx-release! m0)
(define victim (fx-alloc! span))
(fill! victim span 165)
(export!)
(want 'bytes-of-a-later-allocation-overwritten (dirt victim span 165) 0)

;; THE CONTROL, and it is what makes this a lifetime finding rather
;; than "glb-write! writes to memory".  Identical calls with NO release
;; between them: the scratch is still below the water level, still
;; ours, and the later allocation sits above it untouched.  This half
;; must stay green before and after the repair.
(define keep (fx-alloc! span))
(fill! keep span 90)
(export!)
(want 'CONTROL-no-release-means-no-corruption (dirt keep span 90) 0)

(display (if (null? fails) #t fails))
