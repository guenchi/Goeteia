;; expect: #t
;; grade-run! names four tone-mapping modes, and each reaches the shader
;; as its own number.
;;
;; The shader side -- that mode 3 selects Hill's fit and not Narkowicz's
;; -- is measured on a GPU in tonemap-curves-on-gpu.mjs.  This cell holds
;; the Scheme side: 'aces-hill is accepted and uploads 3, the three modes
;; that existed keep the numbers they had, and a name that is not a mode
;; is still refused rather than drawn as something else.
;;
;; WHAT IS READ.  uniform1f as a recording mock logs it.  Each mode is
;; graded through a FRESH grade, because fx-uniform! skips re-sending a
;; uniform whose value has not changed and that memory lives with the
;; program: two grades through one program with the same mode record
;; one upload and then none.
(import (rnrs) (web js) (gfx gl) (gfx glsl) (gfx fx) (gfx post))

(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { width:640, height:480, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', TRIANGLES:'TRI', TRIANGLE_STRIP:'STRIP', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', TEXTURE_2D:'T2D', TEXTURE0:33984, TEXTURE_MIN_FILTER:'MIN', TEXTURE_MAG_FILTER:'MAG', TEXTURE_WRAP_S:'WS', TEXTURE_WRAP_T:'WT', LINEAR:'LIN', LINEAR_MIPMAP_LINEAR:'LML', CLAMP_TO_EDGE:'CL', RGBA:'RGBA', UNSIGNED_BYTE:'UB', NEAREST:'NEA', FRAMEBUFFER:'FB', DEPTH_ATTACHMENT:'DA', COLOR_ATTACHMENT0:'CA0', RENDERBUFFER:'RB', DEPTH_COMPONENT16:'D16', DEPTH_COMPONENT24:'D24', DEPTH_COMPONENT:'DC', UNSIGNED_INT:'UI', NONE:'NONE', createShader(k){ return {kind:k} }, shaderSource(){}, compileShader(){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(){}, linkProgram(){}, getProgramParameter(){ return true }, bindAttribLocation(){}, createVertexArray(){ return {id:'V'+(this._v=(this._v||0)+1)} }, bindVertexArray(){}, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, bindTexture(t,tex){}, texParameteri(){}, generateMipmap(){}, texImage2D(){}, activeTexture(u){}, createFramebuffer(){ return {id:'F'+(this._fb=(this._fb||0)+1)} }, bindFramebuffer(t,fb){}, framebufferTexture2D(){}, createRenderbuffer(){ return {id:'R'+(this._rb=(this._rb||0)+1)} }, bindRenderbuffer(){}, renderbufferStorage(){}, framebufferRenderbuffer(){}, drawBuffers(){}, enable(){}, disable(){}, blendFunc(){}, clearColor(){}, clear(){}, useProgram(p){}, bindBuffer(){}, bufferData(){}, enableVertexAttribArray(){}, vertexAttribPointer(){}, uniform1f(loc,x){ push('uniform1f', loc.id, x.toFixed(2)) }, uniform2f(){}, uniform1i(){}, uniform4f(){}, uniformMatrix4fv(){}, drawArrays(m,f,c){ push('draw', m, f, c) }, viewport(){} } } }")
(fx-init! (js-get (js-global) "__mockcanvas"))

(define log (js-get (js-global) "__gllog"))
(define (entries)
  (let loop ((i 0) (out '()))
    (if (= i (js->number (js-get log "length")))
        (reverse out)
        (loop (+ i 1) (cons (js->string (js-index log i)) out)))))
(define (prefixed? s p)
  (and (>= (string-length s) (string-length p)) (string=? (substring s 0 (string-length p)) p)))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

(define scene (fx-target! 64 64))

;; The u_mode uploads one grade of the given mode records, in order.
(define (mode-uploads mode)
  (js-set! log "length" 0)
  (cmd-begin!)
  (grade-run! (make-grade) (fx-target-texture scene) #f mode 1.0 64 64)
  (cmd-flush!)
  (let loop ((l (entries)) (out '()))
    (cond ((null? l) (reverse out))
          ((prefixed? (car l) "uniform1f:U:u_mode:")
           (loop (cdr l) (cons (substring (car l) 19 (string-length (car l))) out)))
          (else (loop (cdr l) out)))))

;; Each row is guarded, so that a mode the tree does not know yet reads
;; as a refusal in that row rather than ending the program.
(define (uploads-or-refusal mode)
  (guard (e (#t (list 'refused (condition-who e)))) (mode-uploads mode)))
(want "'aces-hill reaches the shader as 3" (uploads-or-refusal 'aces-hill) '("3.00"))
(want "'aces still reaches it as 2" (uploads-or-refusal 'aces) '("2.00"))
(want "'reinhard still as 1" (uploads-or-refusal 'reinhard) '("1.00"))
(want "'none still as 0" (uploads-or-refusal 'none) '("0.00"))
(want "a name that is not a mode is refused, not drawn as another"
      (guard (e (#t (condition-who e))) (mode-uploads 'filmic) 'drawn)
      'grade-run!)
;; CONTROL for the instrument: a grade that ran recorded a draw, so an
;; empty upload list above would be a failure to upload, not a mock that
;; saw nothing.
(want "CONTROL a grade draws once"
      (begin (mode-uploads 'aces)
             (length (filter (lambda (s) (prefixed? s "draw:")) (entries))))
      1)

(display (if (null? fails) #t (reverse fails)))
