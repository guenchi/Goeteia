;; expect: #t
;; Public fx calls must retain distinct VAOs without packed slot limits.
(import (rnrs) (web js) (gfx gl) (gfx fx))

(js-eval "globalThis.__vaoCount = 0; globalThis.__boundVao = null;
globalThis.__canvas = { width:64, height:64, getContext() { return {
  VERTEX_SHADER:35633, FRAGMENT_SHADER:35632, COMPILE_STATUS:35713,
  LINK_STATUS:35714, ARRAY_BUFFER:34962, FLOAT:5126,
  createShader(){ return {} }, shaderSource(){}, compileShader(){},
  getShaderParameter(){ return true }, createProgram(){ return {} },
  attachShader(){}, linkProgram(){}, getProgramParameter(){ return true },
  bindAttribLocation(){}, createBuffer(){ return {} },
  createVertexArray(){ return {id:++globalThis.__vaoCount} },
  bindVertexArray(v){ globalThis.__boundVao = v },
  useProgram(){}, bindBuffer(){}, enableVertexAttribArray(){},
  vertexAttribPointer(){}, vertexAttribDivisor(){}
} } }")
(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display name) (newline)))
(define (count-vaos) (js->number (js-get (js-global) "__vaoCount")))
(define (bound-vao)
  (js->number (js-get (js-get (js-global) "__boundVao") "id")))
(define (program!)
  (fx-program!
   '((attribute vec2 a_pos) (attribute vec2 i_offset)
     (define (main) void (set! gl_Position (vec4 (+ a_pos i_offset) (fl 0) (fl 1)))))
   '((precision mediump float)
     (define (main) void (set! gl_FragColor (vec4 (fl 1)))))))
(define (reserve-through! slot)
  (let loop () (when (< (fx-slot!) slot) (loop))))
(define (use! p b i stride)
  (cmd-begin!)
  (if (< i 0) (fx-use! p b stride) (fx-use-instanced! p b i))
  (cmd-flush!)
  (bound-vao))

(fx-init! (js-get (js-global) "__canvas"))
(define p (program!))
(define a (fx-buffer!))
(define b (fx-buffer!))
(reserve-through! 1022)
(define inst (fx-buffer!))
(check "fixture uses legal slots below 1024"
       (and (= (fx-program-slot p) 0) (= a 1) (= b 2) (= inst 1023)))
;; Previously (0,1,1023) and (0,2,-1) both packed to 2048.
(define av (use! p a inst 8))
(define bv (use! p b -1 8))
(check "instance carry must not alias the next vertex buffer" (not (= av bv)))
(check "first tuple reuses its own VAO" (= av (use! p a inst 8)))
(check "second tuple reuses its own VAO" (= bv (use! p b -1 8)))
(define wide (use! p b -1 16))
(check "explicit strides remain separate" (not (= wide bv)))
(check "default stride survives a wider binding" (= bv (use! p b -1 8)))
(check "wider stride is cached" (= wide (use! p b -1 16)))

;; Resource slots count programs, uniforms, textures and buffers together.
(reserve-through! 2047)
(define high (program!))
(define before (count-vaos))
(define hv (use! high a inst 8))
(do ((i 0 (+ i 1))) ((= i 8))
  (check "large program key reuses its VAO" (= hv (use! high a inst 8))))
(check "large program allocates exactly once" (= 1 (- (count-vaos) before)))
(reserve-through! 4095)
(define large-buffer (fx-buffer!))
(define lv (use! high large-buffer inst 8))
(check "large buffer slots stay distinct" (not (= lv hv)))
(check "large buffer slots reuse their VAO" (= lv (use! high large-buffer inst 8)))
(check "program identity stays distinct" (not (= av hv)))

;; Reinitializing a context retires every VAO, including identical slot tuples.
(fx-init! (js-get (js-global) "__canvas"))
(define fresh (program!))
(define fresh-buffer (fx-buffer!))
(check "initialization retires the cache"
       (not (= bv (use! fresh fresh-buffer -1 8))))
(= failed 0)
