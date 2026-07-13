;; expect: #t
;; The GL command buffer against a recording mock: Scheme encodes a
;; frame of commands into the staging memory, one replay call decodes
;; them into gl.* calls with the right arguments, and BUFFER-DATA
;; hands the replayer the very floats Scheme wrote.
(import (rnrs) (web js) (web gl))

(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', POINTS:'PTS', LINES:'LNS', TRIANGLES:'TRI', TRIANGLE_STRIP:'STRIP', createShader(k){ return {kind:k} }, shaderSource(s,src){ s.src = src }, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, BLEND:'BL', SRC_ALPHA:'SA', ONE:'ONE', ONE_MINUS_SRC_ALPHA:'OMSA', enable(c){ push('gEnable', c) }, disable(c){ push('gDisable', c) }, blendFunc(a,b){ push('blendFunc', a, b) }, clearColor(...a){ push('clearColor', ...a.map(x=>x.toFixed(2))) }, clear(bits){ push('clear', bits) }, useProgram(p){ push('useProgram', p.id) }, bindBuffer(t,b){ push(t==='EAB'?'bindIndex':'bindBuffer', b.id) }, bufferData(t,arr,u){ push('bufferData', Array.from(arr).map(x=>x.toFixed(2)).join(',')) }, DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', uniformMatrix4fv(loc,tr,arr){ push('uniformMat4', loc.id, arr.length, arr[0].toFixed(2), arr[12].toFixed(2)) }, uniform3f(loc,x,y,z){ push('uniform3f', loc.id, x.toFixed(2), y.toFixed(2), z.toFixed(2)) }, drawElements(m,c,t,o){ push('drawElements', m, c, t) }, enableVertexAttribArray(l){ push('enable', l) }, vertexAttribPointer(...a){ push('attrib', a.join(',')) }, uniform1f(loc,x){ push('uniform1f', loc.id, x.toFixed(2)) }, uniform4f(loc,...a){ push('uniform4f', loc.id, a.map(x=>x.toFixed(1)).join(',')) }, drawArrays(m,f,c){ push('draw', m, f, c) }, viewport(...a){ push('viewport', a.join(',')) }, TEXTURE_2D:'T2D', TEXTURE0:33984, TEXTURE_MIN_FILTER:'MIN', TEXTURE_MAG_FILTER:'MAG', TEXTURE_WRAP_S:'WS', TEXTURE_WRAP_T:'WT', LINEAR:'LIN', CLAMP_TO_EDGE:'CL', RGBA:'RGBA', UNSIGNED_BYTE:'UB', createFramebuffer(){ return {id:'F'+(this._fb=(this._fb||0)+1)} }, bindFramebuffer(t,fb){ push('bindFB', fb ? fb.id : 'null') }, framebufferTexture2D(t,a,tt,tex,l){ push('fbTex', a, tex.id) }, createRenderbuffer(){ return {id:'R'+(this._rb=(this._rb||0)+1)} }, bindRenderbuffer(t,rb){ push('bindRB', rb.id) }, renderbufferStorage(t,f,w,h){ push('rbStore', f, w, h) }, framebufferRenderbuffer(t,a,rt,rb){ push('fbRB', a, rb.id) }, drawBuffers(arr){ push('drawBuffers', arr.join(',')) }, DEPTH_COMPONENT24:'D24', DEPTH_COMPONENT:'DC', UNSIGNED_INT:'UI', NEAREST:'NEA', FRAMEBUFFER:'FB', DEPTH_ATTACHMENT:'DA', COLOR_ATTACHMENT0:'CA0', RENDERBUFFER:'RB', DEPTH_COMPONENT16:'D16', NONE:'NONE', createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, bindTexture(t,tex){ push('bindTexture', tex.id) }, UNPACK_PREMULTIPLY_ALPHA_WEBGL:'UPA', pixelStorei(k,v){ push('pixelStore', k, v) }, texParameteri(t,k,v){ push('texParam', k, v) }, texImage2D(...a){ const d = a[a.length-1]; push('texImage', d ? d.id : 'null') }, activeTexture(u){ push('activeTexture', u) }, uniform1i(loc,v){ push('uniform1i', loc.id, v) }, uniform2f(loc,x,y){ push('uniform2f', loc.id, x.toFixed(2), y.toFixed(2)) }, bindAttribLocation(p,i,n){ push('bindAttrib', i, n) } } } }")

;; attach and set up resource slots
(gl-attach! (js-get (js-global) "__mockcanvas"))
(gl-program! 0 "void main(){gl_Position=vec4(0);}" "void main(){}")
(gl-buffer! 1)
(gl-uniform! 2 0 "u_time")

;; vertex data straight into the staging memory (3 points, xy)
(cmd-region! 0)
(%mem-f32-set! 1024 0.5)
(%mem-f32-set! 1028 -0.5)
(%mem-f32-set! 1032 0.25)
(%mem-f32-set! 1036 0.75)
(%mem-f32-set! 1040 -1.0)
(%mem-f32-set! 1044 1.0)

;; one frame of commands, one flush
(cmd-begin!)
(cmd-viewport! 0 0 640 480)
(cmd-blend! 'alpha)
(cmd-clear! 0.1 0.2 0.3 1.0)
(cmd-use-program! 0)
(cmd-bind-buffer! 1)
(cmd-buffer-data! 1024 24)
(cmd-vertex-attrib! 0 2 0 0)
(cmd-uniform1f! 2 3.5)
(cmd-uniform4f! 2 1.0 0.5 0.0 1.0)
(cmd-draw-arrays! GL-POINTS 0 3)
(cmd-flush!)

;; read the recorded call log back
(define log (js-get (js-global) "__gllog"))
(define (entry i) (js->string (js-index log i)))
(define n (js->number (js-get log "length")))

(define expected
  (list "viewport:0,0,640,480"
        "gEnable:BL"
        "blendFunc:SA:OMSA"
        "clearColor:0.10:0.20:0.30:1.00"
        "clear:16640"                    ; COLOR (16384) | DEPTH (256)
        "useProgram:P1"
        "bindBuffer:B1"
        "bufferData:0.50,-0.50,0.25,0.75,-1.00,1.00"
        "enable:0"
        "attrib:0,2,F,false,0,0"
        "uniform1f:U:u_time:3.50"
        "uniform4f:U:u_time:1.0,0.5,0.0,1.0"
        "draw:PTS:0:3"))

(define (check i exp)
  (or (string=? (entry i) exp)
      (begin (display "mismatch at ") (display i) (display ": got ")
             (display (entry i)) (display " want ") (display exp) (newline)
             #f)))

(and (= n (length expected))
     (let loop ((i 0) (es expected))
       (or (null? es)
           (and (check i (car es))
                (loop (+ i 1) (cdr es)))))
     ;; a second frame reuses the region: encode fewer commands, replay
     ;; must stop at the new end, not run into stale words
     (begin (cmd-begin!)
            (cmd-draw-arrays! GL-TRIANGLES 0 3)
            (cmd-flush!)
            (string=? (entry n) "draw:TRI:0:3"))
     ;; --- textures, attribute binding, the new uniforms ---
     (let ((base (js->number (js-get log "length"))))
       (gl-texture! 3)
       (gl-texture-upload! 3 (js-eval "({id:'CV'})"))
       (gl-program! 4 "void main(){gl_Position=vec4(0);}" "void main(){}"
                    "a_pos,a_uv")
       (cmd-begin!)
       (cmd-bind-texture! 0 3)
       (cmd-uniform1i! 2 0)
       (cmd-uniform2f! 2 800.0 600.0)
       (let ((words (cmd-pos)))          ; 3 + 3 + 4 words encoded
         (cmd-flush!)
         (and (= words 40)
              (let loop ((i base)
                         (es (list "bindTexture:T1"
                                   "texParam:MIN:LIN" "texParam:MAG:LIN"
                                   "texParam:WS:CL" "texParam:WT:CL"
                                   "bindTexture:T1" "texImage:CV"
                                   "bindAttrib:0:a_pos" "bindAttrib:1:a_uv"
                                   "activeTexture:33984" "bindTexture:T1"
                                   "uniform1i:U:u_time:0"
                                   "uniform2f:U:u_time:800.00:600.00")))
                (or (null? es)
                    (and (check i (car es))
                         (loop (+ i 1) (cdr es))))))))
     ;; --- 3D: matrix uniform, depth test, indexed draws ---
     (let ((base (js->number (js-get log "length"))))
       (%mem-i32-set! 2048 (+ 0 (* 65536 1)))   ; u16 pairs 0,1 and 2,2
       (%mem-i32-set! 2052 (+ 2 (* 65536 2)))
       (cmd-begin!)
       (cmd-depth! #t)
       (cmd-bind-index! 1)
       (cmd-index-data! 2048 8)
       (cmd-uniform-matrix4! 2
        (vector 1.0 0.0 0.0 0.0  0.0 1.0 0.0 0.0
                0.0 0.0 1.0 0.0  5.0 6.0 7.0 1.0))
       (cmd-uniform3f! 2 0.1 0.2 0.3)
       (cmd-draw-elements! GL-TRIANGLES 6)
       (cmd-depth! #f)
       (cmd-flush!)
       (let loop ((i base)
                  (es (list "gEnable:DT"
                            "bindIndex:B1"
                            "bufferData:0.00,1.00,2.00,2.00"
                            "uniformMat4:U:u_time:16:1.00:5.00"
                            "uniform3f:U:u_time:0.10:0.20:0.30"
                            "drawElements:TRI:6:US"
                            "gDisable:DT")))
         (or (null? es)
             (and (check i (car es))
                  (loop (+ i 1) (cdr es))))))
     ;; --- premultiplied uploads and blending ---
     (let ((base (js->number (js-get log "length"))))
       (gl-texture-upload! 3 (js-eval "({id:'IMG'})") #t)
       (cmd-begin!)
       (cmd-blend! 'premul)
       (cmd-flush!)
       (let loop ((i base)
                  (es (list "pixelStore:UPA:true"
                            "bindTexture:T1" "texImage:IMG"
                            "pixelStore:UPA:false"
                            "gEnable:BL" "blendFunc:ONE:OMSA")))
         (or (null? es)
             (and (check i (car es))
                  (loop (+ i 1) (cdr es))))))
     ;; --- offscreen render targets (webgl2) ---
     (let ((base (js->number (js-get log "length"))))
       (gl-target! 5 6 256 128)          ; color + depth renderbuffer
       (gl-target! 7 8 512 512 #t)       ; depth-only, for shadow maps
       (cmd-begin!)
       (cmd-bind-target! 5)
       (cmd-bind-canvas!)
       (cmd-flush!)
       (let loop ((i base)
                  (es (list "bindTexture:T2" "texImage:null"
                            "texParam:MIN:LIN" "texParam:MAG:LIN"
                            "texParam:WS:CL" "texParam:WT:CL"
                            "bindFB:F1" "fbTex:CA0:T2"
                            "bindRB:R1" "rbStore:D16:256:128"
                            "fbRB:DA:R1" "bindFB:null"
                            "bindTexture:T3" "texImage:null"
                            "texParam:MIN:NEA" "texParam:MAG:NEA"
                            "texParam:WS:CL" "texParam:WT:CL"
                            "bindFB:F2" "fbTex:DA:T3"
                            "drawBuffers:NONE" "bindFB:null"
                            "bindFB:F1" "bindFB:null")))
         (or (null? es)
             (and (check i (car es))
                  (loop (+ i 1) (cdr es)))))))
