;; expect: #t
;; (web scene) against the recording GL mock: the template builds
;; once, geometry uploads on the first frame only, and a signal hole
;; moves a node by updating one field -- the next frame's model
;; matrix carries the new translation.
(import (rnrs) (web js) (web gl) (web glsl) (web fx) (web mat)
        (web mesh) (web reactive) (web scene))

(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { width:640, height:480, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', POINTS:'PTS', LINES:'LNS', TRIANGLES:'TRI', TRIANGLE_STRIP:'STRIP', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', BLEND:'BL', SRC_ALPHA:'SA', ONE:'ONE', ONE_MINUS_SRC_ALPHA:'OMSA', createShader(k){ return {kind:k} }, shaderSource(s,src){}, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, bindAttribLocation(p,i,n){ push('bindAttrib', i, n) }, createVertexArray(){ return {id:'V'+(this._v=(this._v||0)+1)} }, bindVertexArray(){}, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, enable(c){ push('gEnable', c) }, disable(c){ push('gDisable', c) }, blendFunc(a,b){ push('blendFunc', a, b) }, clearColor(...a){ push('clearColor', ...a.map(x=>x.toFixed(2))) }, clear(bits){ push('clear', bits) }, useProgram(p){ push('useProgram', p.id) }, bindBuffer(t,b){ push(t==='EAB'?'bindIndex':'bindBuffer', b.id) }, bufferData(t,arr,u){ push('bufferData', arr.length) }, enableVertexAttribArray(l){ push('enable', l) }, vertexAttribPointer(...a){ push('attrib', a.join(',')) }, uniform1f(loc,x){ push('uniform1f', loc.id, x.toFixed(2)) }, uniform2f(loc,x,y){ push('uniform2f', loc.id, x.toFixed(2), y.toFixed(2)) }, uniform3f(loc,x,y,z){ push('uniform3f', loc.id, x.toFixed(2), y.toFixed(2), z.toFixed(2)) }, uniform4f(loc,...a){ push('uniform4f', loc.id, a.map(x=>x.toFixed(1)).join(',')) }, uniformMatrix4fv(loc,tr,arr){ push('uniformMat4', loc.id, arr.length, arr[0].toFixed(2), arr[12].toFixed(2)) }, uniform1i(loc,v){ push('uniform1i', loc.id, v) }, activeTexture(u){ push('activeTexture', u) }, bindTexture(t,tex){ push('bindTexture', tex ? tex.id : 'null') }, createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, texParameteri(){}, TEXTURE0:33984, TEXTURE_2D:'T2D', TEXTURE_CUBE_MAP:'TCM', drawArrays(m,f,c){ push('draw', m, f, c) }, drawElements(m,c,t,o){ push('drawElements', m, c, t) }, viewport(...a){ push('viewport', a.join(',')) } } } }")

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
(define uploads-before (count-log "bufferData"))
(cmd-begin!)
(sgl-draw! sc2)
(cmd-flush!)
(define mat-ok
  (and ;; three visible nodes drew; the far box was culled entirely
       (= (- (count-log "drawElements") draws-before) 3)
       (= (- (count-log "bufferData") uploads-before) 6)
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

;; the culled box never even uploaded its geometry
(cmd-begin!)
(sgl-draw! sc2)
(cmd-flush!)
(define cull-ok
  (and (= (- (count-log "drawElements") draws-before) 6)
       (= (- (count-log "bufferData") uploads-before) 6)))

(and frame1-ok frame2-ok mat-ok cull-ok)
