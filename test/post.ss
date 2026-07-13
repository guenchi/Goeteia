;; expect: #t
;; (web post): the packaged threshold/blur/composite chains against a
;; recording mock -- pass count, target routing, bindings, tonemap.
(import (rnrs) (web js) (web gl) (web glsl) (web fx) (web post))

(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { width:640, height:480, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', TRIANGLES:'TRI', TRIANGLE_STRIP:'STRIP', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', TEXTURE_2D:'T2D', TEXTURE0:33984, TEXTURE_MIN_FILTER:'MIN', TEXTURE_MAG_FILTER:'MAG', TEXTURE_WRAP_S:'WS', TEXTURE_WRAP_T:'WT', LINEAR:'LIN', LINEAR_MIPMAP_LINEAR:'LML', CLAMP_TO_EDGE:'CL', RGBA:'RGBA', UNSIGNED_BYTE:'UB', NEAREST:'NEA', FRAMEBUFFER:'FB', DEPTH_ATTACHMENT:'DA', COLOR_ATTACHMENT0:'CA0', RENDERBUFFER:'RB', DEPTH_COMPONENT16:'D16', DEPTH_COMPONENT24:'D24', DEPTH_COMPONENT:'DC', UNSIGNED_INT:'UI', NONE:'NONE', createShader(k){ return {kind:k} }, shaderSource(){}, compileShader(){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(){}, linkProgram(){}, getProgramParameter(){ return true }, bindAttribLocation(){}, createVertexArray(){ return {id:'V'+(this._v=(this._v||0)+1)} }, bindVertexArray(){}, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, bindTexture(t,tex){ push('bindTexture', tex ? tex.id : 'null') }, texParameteri(){}, generateMipmap(){}, texImage2D(){}, activeTexture(u){ push('activeTexture', u) }, createFramebuffer(){ return {id:'F'+(this._fb=(this._fb||0)+1)} }, bindFramebuffer(t,fb){ push('bindFB', fb ? fb.id : 'null') }, framebufferTexture2D(){}, createRenderbuffer(){ return {id:'R'+(this._rb=(this._rb||0)+1)} }, bindRenderbuffer(){}, renderbufferStorage(){}, framebufferRenderbuffer(){}, drawBuffers(){}, enable(){}, disable(){}, blendFunc(){}, clearColor(){}, clear(){}, useProgram(p){ push('useProgram', p.id) }, bindBuffer(){}, bufferData(){}, enableVertexAttribArray(){}, vertexAttribPointer(){}, uniform1f(loc,x){ push('uniform1f', loc.id, x.toFixed(2)) }, uniform2f(loc,x,y){ push('uniform2f', loc.id, x.toFixed(3), y.toFixed(3)) }, uniform1i(loc,v){ push('uniform1i', loc.id, v) }, uniform4f(){}, uniformMatrix4fv(){}, drawArrays(m,f,c){ push('draw', m, f, c) }, viewport(...a){ push('viewport', a.join(',')) } } } }")

(fx-init! (js-get (js-global) "__mockcanvas"))

(define log (js-get (js-global) "__gllog"))
(define (entry i) (js->string (js-index log i)))
(define (log-len) (js->number (js-get log "length")))
(define (count-from base s)
  (let loop ((i base) (n 0))
    (if (>= i (log-len))
        n
        (loop (+ i 1) (if (string=? (entry i) s) (+ n 1) n)))))
(define (has-from? base s) (> (count-from base s) 0))

;; a scene target (T1/F1), then the bloom kit:
;; bright T2/F2, blur-a T3/F3, blur-b T4/F4
(define scene (fx-target! 640 480))
(define bloom (make-bloom 200 150))

;; ---- one bloom round ----
(define base1 (log-len))
(cmd-begin!)
(bloom-run! bloom (fx-target-texture scene) 1.0 2.0)
(cmd-flush!)
(define run-ok
  (and (= (count-from base1 "draw:STRIP:0:4") 5)   ; threshold + 4 blur
       (has-from? base1 "bindFB:F2")               ; into bright
       (has-from? base1 "bindFB:F3")               ; blur ping
       (has-from? base1 "bindFB:F4")               ; blur pong
       (has-from? base1 "viewport:0,0,200,150")
       (has-from? base1 "bindTexture:T1")          ; sampled the scene
       (has-from? base1 "uniform2f:U:u_edges:1.000:2.000")))

;; ---- composite to the canvas, reinhard ----
(define base2 (log-len))
(cmd-begin!)
(bloom-composite! bloom (fx-target-texture scene) #f 'reinhard 1.1)
(cmd-flush!)
(define comp-ok
  (and (= (count-from base2 "draw:STRIP:0:4") 1)
       (has-from? base2 "bindFB:null")             ; the canvas
       (has-from? base2 "viewport:0,0,640,480")
       (has-from? base2 "bindTexture:T4")          ; the blurred glow
       (has-from? base2 "uniform1f:U:u_gain:1.10")
       (has-from? base2 "uniform1f:U:u_mode:2.00")))

;; ---- the standalone blur: one round = two passes ----
(define blr (make-blur 100 50))                    ; T5/F5, T6/F6
(define base3 (log-len))
(cmd-begin!)
(define blurred (blur-run! blr (fx-target-texture scene) 1))
(cmd-flush!)
(define blur-ok
  (and (= (count-from base3 "draw:STRIP:0:4") 2)
       (has-from? base3 "viewport:0,0,100,50")
       (has-from? base3 "uniform2f:U:u_texel:0.010:0.020")
       (= blurred (blur-texture blr))))

;; ---- grade: linear in, exposure + tonemap + gamma out ----
(define grade (make-grade))
(define base4 (log-len))
(cmd-begin!)
(grade-run! grade (fx-target-texture scene) #f 'aces 1.3 640 480)
(cmd-flush!)
(define grade-ok
  (and (= (count-from base4 "draw:STRIP:0:4") 1)
       (has-from? base4 "bindFB:null")
       (has-from? base4 "bindTexture:T1")
       (has-from? base4 "uniform1f:U:u_exposure:1.30")
       (has-from? base4 "uniform1f:U:u_mode:2.00")))

;; ---- fxaa: one pass over display-ready color ----
(define fxaa (make-fxaa))
(define base5 (log-len))
(cmd-begin!)
(fxaa-run! fxaa (fx-target-texture scene) #f 640 480)
(cmd-flush!)
(define fxaa-ok
  (and (= (count-from base5 "draw:STRIP:0:4") 1)
       (has-from? base5 "bindFB:null")
       (has-from? base5 "bindTexture:T1")
       (has-from? base5 "uniform2f:U:u_texel:0.002:0.002")))

(and run-ok comp-ok blur-ok grade-ok fxaa-ok)
