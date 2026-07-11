;; expect: #t
;; The GL command buffer against a recording mock: Scheme encodes a
;; frame of commands into the staging memory, one replay call decodes
;; them into gl.* calls with the right arguments, and BUFFER-DATA
;; hands the replayer the very floats Scheme wrote.
(import (rnrs) (web js) (web gl))

(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', POINTS:'PTS', LINES:'LNS', TRIANGLES:'TRI', TRIANGLE_STRIP:'STRIP', createShader(k){ return {kind:k} }, shaderSource(s,src){ s.src = src }, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, clearColor(...a){ push('clearColor', ...a.map(x=>x.toFixed(2))) }, clear(bits){ push('clear', bits) }, useProgram(p){ push('useProgram', p.id) }, bindBuffer(t,b){ push('bindBuffer', b.id) }, bufferData(t,arr,u){ push('bufferData', Array.from(arr).map(x=>x.toFixed(2)).join(',')) }, enableVertexAttribArray(l){ push('enable', l) }, vertexAttribPointer(...a){ push('attrib', a.join(',')) }, uniform1f(loc,x){ push('uniform1f', loc.id, x.toFixed(2)) }, uniform4f(loc,...a){ push('uniform4f', loc.id, a.map(x=>x.toFixed(1)).join(',')) }, drawArrays(m,f,c){ push('draw', m, f, c) }, viewport(...a){ push('viewport', a.join(',')) } } } }")

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
            (string=? (entry n) "draw:TRI:0:3")))
