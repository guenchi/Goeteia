;; expect: #t
;; A glTF base colour factor reaches the shader encoded as sRGB.
;;
;; The mesh shaders take u_color as sRGB and decode it before lighting --
;; that is the contract docs/api.md states.  The glTF specification says
;; baseColorFactor is LINEAR; only the base colour texture is sRGB.  The
;; loader used to hand the factor to u_color untouched, so the shader
;; decoded a value that was already linear: a factor of 0.5 was lit as
;; about 0.21, and every model with a factor below one drew darker than
;; its author made it.  The factor is now encoded on the CPU: once when
;; the model is loaded, and again at any draw that finds the colour
;; changed since.  gprim-color stays linear, because glb-write! writes it
;; back to a file as baseColorFactor.
;;
;; And a material with no factor reads as the specification's white.  It
;; used to read as a 0.8 grey, and since the factor multiplies the base
;; colour texture, every texture in such a material was multiplied by
;; that grey -- about 0.6 in linear light once the shader decoded it --
;; instead of drawn as the file has it.
;;
;; WHAT IS READ.  The value handed to uniform4f, recorded by a mock GL to
;; four decimals.  The other recording mocks in this tree keep one
;; decimal, which can tell encoded from not encoded but not correctly
;; encoded from nearly so.  Every expected value below was computed in
;; double precision from the sRGB definition before the encoder existed.
;; Alpha is not encoded: it is linear in glTF and the shaders do not
;; decode it.
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx mesh) (gfx mat) (gfx gltf) (gfx glb))

(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { width:64, height:64, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', TRIANGLES:'TRI', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', createTexture(){ return {} }, bindTexture(){}, texParameteri(){}, generateMipmap(){}, texImage2D(){}, activeTexture(){}, uniform1i(){}, uniform2f(){}, createShader(k){ return {kind:k} }, shaderSource(){}, compileShader(){}, getShaderParameter(){ return true }, createProgram(){ return {} }, attachShader(){}, linkProgram(){}, getProgramParameter(){ return true }, bindAttribLocation(){}, createVertexArray(){ return {} }, bindVertexArray(){}, createBuffer(){ return {} }, getUniformLocation(p,n){ return {id:'U:'+n} }, useProgram(){}, bindBuffer(){}, bufferData(){}, enableVertexAttribArray(){}, vertexAttribPointer(){}, uniform1f(){}, uniform3f(){}, uniform4f(loc,...a){ push('uniform4f', loc.id, a.map(x=>x.toFixed(4)).join(',')) }, uniformMatrix4fv(){}, drawElements(){}, viewport(){}, enable(){}, clearColor(){}, clear(){} } } }")
(define gllog (js-get (js-global) "__gllog"))
(fx-init! (js-get (js-global) "__mockcanvas"))

;; one triangle, position and normal
(define layout '(position normal))
(define stride (glb-stride layout))
(define vbase (fx-alloc! (* 3 stride)))
(let v ((i 0))
  (when (< i 3)
    (let ((a (+ vbase (* i stride))))
      (%mem-f32-set! a (exact->inexact i)) (%mem-f32-set! (+ a 4) 0.0) (%mem-f32-set! (+ a 8) 0.0)
      (%mem-f32-set! (+ a 12) 0.0) (%mem-f32-set! (+ a 16) 1.0) (%mem-f32-set! (+ a 20) 0.0))
    (v (+ i 1))))
(define ibase (fx-alloc! 8))
(%mem-u8-set! ibase 0) (%mem-u8-set! (+ ibase 1) 0) (%mem-u8-set! (+ ibase 2) 1)
(%mem-u8-set! (+ ibase 3) 0) (%mem-u8-set! (+ ibase 4) 2) (%mem-u8-set! (+ ibase 5) 0)
(define (prim . opts) (append (list layout vbase 3 ibase 3) opts))


;; The u_color values one draw of a parsed model uploads, in order.  It
;; takes the parsed object rather than the file, so the SAME object can be
;; drawn twice and then inspected: a first draw that encoded the stored
;; colour in place would upload correctly once and wrongly after.
;;
;; Each draw gets a FRESH program, because fx-uniform! skips re-sending a
;; uniform whose value has not changed, and that memory lives with the
;; program.  Drawn through one program, two draws that upload the same
;; colour record one upload and then none -- so "the same colour twice"
;; read as two empty lists, equal, and passed while measuring nothing.
;; And every draw here must record exactly one upload: an empty list is
;; a failure of the instrument, not an answer.
(define (colors-of g)
  (js-set! gllog "length" 0)
  (cmd-begin!) (gltf-draw! g (fx-program! mesh-lit-vs mesh-lit-fs) (m4-identity)) (cmd-flush!)
  (let loop ((i 0) (out '()))
    (if (= i (js->number (js-get gllog "length")))
        (reverse out)
        (let ((e (js->string (js-index gllog i))))
          (loop (+ i 1)
                (if (and (> (string-length e) 20) (string=? (substring e 0 20) "uniform4f:U:u_color:"))
                    (cons (substring e 20 (string-length e)) out)
                    out))))))
(define (one-upload name got)
  (unless (= (length got) 1)
    (set! fails (cons (list name 'recorded (length got) 'uploads 'want 1) fails)))
  got)

(define (parse loc) (gltf-parse (car loc) (cdr loc)))
(define (colors-of-draw loc) (one-upload "a draw" (colors-of (parse loc))))

(define (material color)
  (list color (cons 1.0 1.0) (vector 0.0 0.0 0.0) #f #f #f #f #f))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

;; 0.5 -> 0.7354, 0.25 -> 0.5371, 0.8 -> 0.9063: every channel is off the
;; curve's fixed points 0 and 1, so an encoder that skipped one channel is
;; seen.  Alpha 0.5 is carried as it is.
(define mid (glb-write! (list (prim 'material 0))
                        'materials (list (material (vector 0.5 0.25 0.8 0.5)))))
(want "a factor of 0.5 is uploaded as its sRGB encoding"
      (colors-of-draw mid) '("0.7354,0.5371,0.9063,0.5000"))

;; The same object drawn twice uploads the same thing twice, and is still
;; linear afterwards.  Encoding in place would give 0.8732 the second time.
(let ((g (parse mid)))
  (let* ((first (one-upload "first draw" (colors-of g))) (second (one-upload "second draw" (colors-of g))))
    (want "a second draw of the same object uploads the same colour" second first)
    (want "and the drawn object's colour is still the linear factor"
          (gprim-color (car (gltf-prims g))) (vector 0.5 0.25 0.8 0.5))))

;; The upload follows the colour at the time of the draw.  gprim-color is
;; a mutable vector; a value encoded once at load time would miss this.
(let ((g (parse mid)))
  (vector-set! (gprim-color (car (gltf-prims g))) 0 0.25)
  (want "a colour changed after loading is encoded as it now is"
        (one-upload "a draw after the change" (colors-of g)) '("0.5371,0.5371,0.9063,0.5000")))

;; 0.002 is below the curve's linear threshold (0.0031308), so it is
;; encoded by the straight segment: 0.002 x 12.92 = 0.0258.  A power law
;; with no linear segment gives 0.0754 here.
(define dark (glb-write! (list (prim 'material 0))
                         'materials (list (material (vector 0.002 0.0 0.0 1.0)))))
(want "a factor below the threshold is encoded by the linear segment"
      (colors-of-draw dark) '("0.0258,0.0000,0.0000,1.0000"))

;; No material at all: the specification's white.
(define none (glb-write! (list (prim))))
(want "a primitive with no material draws with the specification's white"
      (colors-of-draw none) '("1.0000,1.0000,1.0000,1.0000"))

;; A NaN in the colour is refused at the draw, naming it.  It can only get
;; there by a caller changing the vector -- JSON cannot spell NaN -- and
;; uploading it silently draws black with nothing to say why.  The cached
;; encoding compares the colour with =, which is false for NaN, so the
;; encoder sees it every time and refuses it.  (Ruled 2026-09-25.)
(let ((g (parse mid)))
  (vector-set! (gprim-color (car (gltf-prims g))) 1 +nan.0)
  (want "a NaN in the colour is refused at the draw, naming it"
        (guard (e (#t (let any ((l (condition-irritants e)))
                        (and (pair? l)
                             (or (and (real? (car l)) (not (= (car l) (car l))))
                                 (any (cdr l)))))))
          (colors-of g) #f)
        #t))

;; A material that exists but writes no factor: the same white.  The two
;; reach the default by different paths in the loader.
(define nofactor (glb-write! (list (prim 'material 0))
                             'materials (list (list #f (cons 1.0 1.0) (vector 0.0 0.0 0.0) #f #f #f #f #f))))
(want "a material with no factor draws with the specification's white"
      (colors-of-draw nofactor) '("1.0000,1.0000,1.0000,1.0000"))

;; CONTROL for the instrument: whatever was uploaded, every field was
;; recorded with four decimals.  With one decimal -- what the other mocks
;; here keep -- 0.7354 and 0.7 would read alike, and the rows above would
;; be checking whether an encoding happened, not whether it is right.
(define (four-decimals? field)
  (let ((n (string-length field)))
    (let find ((i 0))
      (cond ((= i n) #f)
            ((char=? (string-ref field i) #\.) (= (- n i 1) 4))
            (else (find (+ i 1)))))))
(define (fields s)
  (let loop ((i 0) (start 0) (out '()))
    (cond ((= i (string-length s)) (reverse (cons (substring s start i) out)))
          ((char=? (string-ref s i) #\,) (loop (+ i 1) (+ i 1) (cons (substring s start i) out)))
          (else (loop (+ i 1) start out)))))
(want "CONTROL the mock records four decimals"
      (let ((got (colors-of-draw mid)))
        (and (pair? got)
             (let all ((l (fields (car got))))
               (or (null? l) (and (four-decimals? (car l)) (all (cdr l)))))))
      #t)

(display (if (null? fails) #t (reverse fails)))
