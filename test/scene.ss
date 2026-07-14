;; expect: #t
;; (gfx scene) against the recording GL mock: the template builds
;; once, geometry uploads on the first frame only, and a signal hole
;; moves a node by updating one field -- the next frame's model
;; matrix carries the new translation.
(import (rnrs) (web js) (gfx gl) (gfx glsl) (gfx fx) (gfx mat)
        (gfx mesh) (web reactive) (gfx scene))

(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { width:640, height:480, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', POINTS:'PTS', LINES:'LNS', TRIANGLES:'TRI', TRIANGLE_STRIP:'STRIP', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', BLEND:'BL', SRC_ALPHA:'SA', ONE:'ONE', ONE_MINUS_SRC_ALPHA:'OMSA', createShader(k){ return {kind:k} }, shaderSource(s,src){}, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, bindAttribLocation(p,i,n){ push('bindAttrib', i, n) }, createVertexArray(){ return {id:'V'+(this._v=(this._v||0)+1)} }, bindVertexArray(){}, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, enable(c){ push('gEnable', c) }, disable(c){ push('gDisable', c) }, blendFunc(a,b){ push('blendFunc', a, b) }, clearColor(...a){ push('clearColor', ...a.map(x=>x.toFixed(2))) }, clear(bits){ push('clear', bits) }, useProgram(p){ push('useProgram', p.id) }, bindBuffer(t,b){ push(t==='EAB'?'bindIndex':'bindBuffer', b.id) }, bufferData(t,arr,u){ push('bufferData', arr.length) }, enableVertexAttribArray(l){ push('enable', l) }, vertexAttribPointer(...a){ push('attrib', a.join(',')) }, uniform1f(loc,x){ push('uniform1f', loc.id, x.toFixed(2)) }, uniform2f(loc,x,y){ push('uniform2f', loc.id, x.toFixed(2), y.toFixed(2)) }, uniform3f(loc,x,y,z){ push('uniform3f', loc.id, x.toFixed(2), y.toFixed(2), z.toFixed(2)) }, uniform4f(loc,...a){ push('uniform4f', loc.id, a.map(x=>x.toFixed(1)).join(',')) }, uniformMatrix4fv(loc,tr,arr){ push('uniformMat4', loc.id, arr.length, arr[0].toFixed(2), arr[12].toFixed(2)) }, uniform1i(loc,v){ push('uniform1i', loc.id, v) }, activeTexture(u){ push('activeTexture', u) }, bindTexture(t,tex){ push('bindTexture', tex ? tex.id : 'null') }, createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, texParameteri(){}, TEXTURE0:33984, TEXTURE_2D:'T2D', TEXTURE_CUBE_MAP:'TCM', drawArrays(m,f,c){ push('draw', m, f, c) }, drawElements(m,c,t,o){ push('drawElements', m, c, t) }, vertexAttribDivisor(l,d){ if (d > 0) push('divisor', l, d) }, drawElementsInstanced(m,c,t,o,n){ push('drawInst', m, c, n) }, viewport(...a){ push('viewport', a.join(',')) } } } }")

(define gllog (js-get (js-global) "__gllog"))
(define (log-len) (js->number (js-get gllog "length")))
(define (entry i) (js->string (js-index gllog i)))
(define (prefix? p s)
  (and (<= (string-length p) (string-length s))
       (string=? p (substring s 0 (string-length p)))))
(define (count-log p)
  (let ((n (log-len)))
    (let loop ((i 0) (c 0))
      (if (= i n)
          c
          (loop (+ i 1) (if (prefix? p (entry i)) (+ c 1) c))))))
(define (check-from base es)
  (let loop ((i base) (es es))
    (or (null? es)
        (and (or (string=? (entry i) (car es))
                 (begin (display "mismatch at ") (display i)
                        (display ": got ") (display (entry i))
                        (display " want ") (display (car es)) (newline)
                        #f))
             (loop (+ i 1) (cdr es))))))

(fx-init! (js-get (js-global) "__mockcanvas"))

(define angle (signal 0.0))
(define sc
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (mesh (@ (geometry (box 2 2 2))
                (position-x ,(signal-ref angle))
                (color 1.0 0.0 0.0)))
       (mesh (@ (geometry (sphere 1.0 8 4))
                (position 3.0 0.0 0.0)
                (color 0.0 0.0 1.0)))))

;; frame 1: header uniforms, then both nodes upload and draw
(define base-1 (log-len))
(cmd-begin!)
(sgl-draw! sc)
(cmd-flush!)
(define frame1-ok
  (and (sgl-scene? sc)
       (check-from base-1 '("gEnable:DT" "useProgram:P1"
                            "uniform3f:U:u_light:0.00:1.00:0.00"
                            "uniform1f:U:u_ambient:0.25"))
       (= (count-log "bufferData") 4)   ; box + sphere, verts + indices
       (= (count-log "bufferData:144") 1)
       (= (count-log "bufferData:36") 1)
       (= (count-log "bufferData:270") 1)
       (= (count-log "bufferData:192") 1)
       (= (count-log "attrib:0,3,F,false,24,0") 2)
       (= (count-log "attrib:1,3,F,false,24,12") 2)
       (= (count-log "uniformMat4:U:u_model:16:1.00:0.00") 1)  ; box at x 0
       (= (count-log "uniformMat4:U:u_model:16:1.00:3.00") 1)  ; sphere at 3
       (= (count-log "uniform4f:U:u_color:1.0,0.0,0.0,1.0") 1)
       (= (count-log "drawElements:TRI:36:US") 1)
       (= (count-log "drawElements:TRI:192:US") 1)))

;; frame 2: the signal moved the box; geometry does not re-upload
(signal-set! angle 2.0)
(cmd-begin!)
(sgl-draw! sc)
(cmd-flush!)
(define frame2-ok
  (and (= (count-log "bufferData") 4)   ; still the first frame's four
       (= (count-log "uniformMat4:U:u_model:16:1.00:2.00") 1)
       (= (count-log "drawElements:TRI:36:US") 2)))

;; ---- materials and culling ----
;; one lit box, one box past the far plane (culled), a textured
;; sphere and a pbr sphere against a probe
(define tex-slot (fx-texture!))
(define sky-slot (fx-texture!))          ; stands in for a cube map
(define lut-slot (fx-texture!))
(define sc2
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)
                  (near 0.1) (far 50.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (probe (@ (sky ,sky-slot) (lut ,lut-slot) (mips 5)))
       (mesh (@ (geometry (box 2 2 2)) (color 1.0 0.0 0.0)))
       (mesh (@ (geometry (box 2 2 2)) (position 0.0 0.0 200.0)))
       (mesh (@ (geometry (sphere 1.0 8 4)) (texture ,tex-slot)))
       (mesh (@ (geometry (sphere 1.0 8 4))
                (metallic 1.0) (roughness 0.3)))))
(define draws-before (count-log "drawElements"))
(define idraws-before (count-log "drawInst"))
(define uploads-before (count-log "bufferData"))
(cmd-begin!)
(sgl-draw! sc2)
(cmd-flush!)
(define mat-ok
  (and ;; the two boxes share a geometry: an instanced group whose
       ;; far member is culled, so ONE drawInst carrying ONE instance
       (= (- (count-log "drawInst") idraws-before) 1)
       (= (count-log "drawInst:TRI:36:1") 1)
       ;; the two spheres draw singly (different materials)
       (= (- (count-log "drawElements") draws-before) 2)
       ;; box geometry uploads ONCE (shared), spheres once each,
       ;; plus the instance buffer: 2 + 4 + 1 uploads
       (= (- (count-log "bufferData") uploads-before) 7)
       ;; the textured sphere carries uvs: stride 32, uv at 24
       (= (count-log "attrib:2,2,F,false,32,24") 1)
       ;; each texture binds once at creation, then once this frame
       (= (count-log "bindTexture:T1") 2)
       ;; the probe rides units 0 (cube) and 1 (lut)
       (= (count-log "bindTexture:T2") 2)
       (= (count-log "bindTexture:T3") 2)
       (= (count-log "uniform1i:U:u_sky:0") 1)
       (= (count-log "uniform1i:U:u_lut:1") 1)
       (= (count-log "uniform1f:U:u_mips:5.00") 1)
       (= (count-log "uniform3f:U:u_eye:0.00:0.00:6.00") 1)
       (= (count-log "uniform1f:U:u_metallic:1.00") 1)
       (= (count-log "uniform1f:U:u_roughness:0.30") 1)))

;; frame two: geometry stays put, only the instance buffer re-ships
(cmd-begin!)
(sgl-draw! sc2)
(cmd-flush!)
(define cull-ok
  (and (= (- (count-log "drawInst") idraws-before) 2)
       (= (- (count-log "drawElements") draws-before) 4)
       (= (- (count-log "bufferData") uploads-before) 8)))

;; ---- groups: a parent transform the children inherit ----
(define swing (signal 0.0))
(define sc3
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 14.0) (look-at 0.0 0.0 0.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (group (@ (position 5.0 0.0 0.0) (rotation-y ,(signal-ref swing)))
         (mesh (@ (geometry (box 1 1 1)) (position 1.0 0.0 0.0)
                  (color 1.0 1.0 1.0))))))
(cmd-begin!) (sgl-draw! sc3) (cmd-flush!)
(define group1-ok
  ;; parent at x 5, child at local x 1: the world sits at 6
  (= (count-log "uniformMat4:U:u_model:16:1.00:6.00") 1))
;; half a turn later the child is on the parent's other side
(signal-set! swing 3.14159265)
(cmd-begin!) (sgl-draw! sc3) (cmd-flush!)
(define group2-ok
  (= (count-log "uniformMat4:U:u_model:16:-1.00:4.00") 1))

;; ---- lod: the eye's distance walks the switch list ----
(define hi-tag (string-append "drawElements:TRI:"
                 (number->string (mesh-index-count (mesh-sphere 1.0 10 5)))
                 ":US"))
(define lo-tag (string-append "drawElements:TRI:"
                 (number->string (mesh-index-count (mesh-sphere 1.0 5 3)))
                 ":US"))
(define sc-near                          ; 6 away: under the switch
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 6.0) (look-at 0.0 0.0 0.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (lod (@ (switch 15.0))
         (mesh (@ (geometry (sphere 1.0 10 5)) (color 1.0 0.0 0.0)))
         (mesh (@ (geometry (sphere 1.0 5 3)) (color 1.0 0.0 0.0))))))
(define hi-before (count-log hi-tag))
(define lo-before (count-log lo-tag))
(cmd-begin!) (sgl-draw! sc-near) (cmd-flush!)
(define lod-near-ok
  (and (= (- (count-log hi-tag) hi-before) 1)
       (= (- (count-log lo-tag) lo-before) 0)))
(define sc-far                           ; 40 away: past it
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 40.0) (look-at 0.0 0.0 0.0)
                  (near 0.1) (far 100.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (lod (@ (switch 15.0))
         (mesh (@ (geometry (sphere 1.0 10 5)) (color 1.0 0.0 0.0)))
         (mesh (@ (geometry (sphere 1.0 5 3)) (color 1.0 0.0 0.0))))))
(cmd-begin!) (sgl-draw! sc-far) (cmd-flush!)
(define lod-far-ok
  (and (= (- (count-log hi-tag) hi-before) 1)   ; still just the near one
       (= (- (count-log lo-tag) lo-before) 1)))

;; ---- the batched cull across chunks: seven instances, the 2nd,
;; 5th and 6th out past the far plane -- culled lanes pack down
;; within their chunk of four and across the chunk boundary, so one
;; draw carries exactly the four survivors
(define sc-chunk
  (sgl (camera (@ (fov 0.9) (position 0.0 0.0 8.0) (look-at 0.0 0.0 0.0)
                  (near 0.1) (far 50.0)))
       (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
       (mesh (@ (geometry (box 1 1 1)) (position -3.0 0.0 0.0)))
       (mesh (@ (geometry (box 1 1 1)) (position 0.0 0.0 300.0)))
       (mesh (@ (geometry (box 1 1 1)) (position -1.0 0.0 0.0)))
       (mesh (@ (geometry (box 1 1 1)) (position 1.0 0.0 0.0)))
       (mesh (@ (geometry (box 1 1 1)) (position 0.0 200.0 0.0)))
       (mesh (@ (geometry (box 1 1 1)) (position 0.0 -200.0 0.0)))
       (mesh (@ (geometry (box 1 1 1)) (position 3.0 0.0 0.0)))))
(define chunk-before (count-log "drawInst:TRI:36:4"))
(cmd-begin!) (sgl-draw! sc-chunk) (cmd-flush!)
(define chunk-ok
  (= (- (count-log "drawInst:TRI:36:4") chunk-before) 1))

(and frame1-ok frame2-ok mat-ok cull-ok group1-ok group2-ok
     lod-near-ok lod-far-ok chunk-ok)
