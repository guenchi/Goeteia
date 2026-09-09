;; expect: #t
;; RED ON PURPOSE: fx-mesh! forgets whether a mesh's indices are 16-bit
;; or 32-bit, so a mesh past 65536 vertices is uploaded and drawn as if
;; its indices were u16.
;;
;; ⭐ The mechanism to do this right is already here and already
;; documented.  (gfx mesh) exports mesh-index-u32?, and the comment
;; over it says what a caller is supposed to do with it: "callers ask
;; mesh-index-u32? to pick cmd-index-data32!/cmd-draw-elements32! over
;; the u16 pair".  (gfx gl) provides that pair.  ⇒ Both halves exist,
;; the instruction is written down, and fx-mesh! does not ask.
;;
;; ⚠️ The failure is not a crash.  The GPU reads a u32 index buffer as
;; pairs of u16s: every index becomes two wrong ones, half of them the
;; high half-words of neighbours.  What comes out is a mesh, drawn,
;; made of triangles nobody authored.
;;
;; The cells read the encoded command stream rather than a picture:
;; 17/18 are the u16 upload and draw, 36/37 the u32 pair.  ⇒ No GPU is
;; involved and the reading is the opcode itself, not something
;; downstream of it.
;;
;; The controls are a small mesh, which must keep emitting 17/18 -- a
;; fix that switched everything to 32-bit indices would satisfy the
;; reds and double every small mesh's index memory -- and the boundary
;; itself, since mesh-index-u32? is defined at > 65536 and a cell that
;; only tested a huge mesh would not notice the comparison drifting.
(import (rnrs) (web js) (gfx fx) (gfx gl) (gfx mesh))

;; The GL stub test/fx-vao-cache.ss uses, so fx-init! and fx-buffer!
;; can hand out slots.  ⭐ It cannot fake this file's reading: the
;; opcodes below are words the encoder writes into linear memory, and
;; the stub sits downstream of the command stream, not inside it.  ⇒
;; Whatever the stub answers, it never touches what is measured here.
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
(fx-init! (js-get (js-global) "__canvas"))

(define prog
  (fx-program!
   '((attribute vec3 a_pos)
     (define (main) void (set! gl_Position (vec4 a_pos (fl 1)))))
   '((precision mediump float)
     (define (main) void (set! gl_FragColor (vec4 (fl 1)))))))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

;; ⚠️ READING THE COMMAND STREAM MEANS DECODING IT, NOT SEARCHING IT.
;; The first draft scanned for the words 17/18/36/37 and stopped at the
;; first zero -- which is the operand of the very first command, so it
;; read nothing at all and reported the same empty answer for both
;; meshes.  ⭐ A column of identical readings is the instrument talking
;; about itself.  And searching would have been wrong even had it not
;; stopped: an operand may equal an opcode (this stream carries a byte
;; count of 4 and a slot of 5), so only a sequential walk with each
;; command's operand count can say what is an opcode and what is not.
;;
;; The walk asserts it lands exactly on the sentinel.  If it does not,
;; the table below is wrong and every reading in this file is garbage
;; -- which the cell says rather than leaving to be assumed.
(define CMD (fx-alloc! 65536))
(define SENT -999)
(define (arity op)
  (cond ((= op 2) 1) ((= op 27) 8) ((= op 16) 1) ((= op 4) 2)
        ((= op 17) 2) ((= op 18) 2) ((= op 36) 2) ((= op 37) 2)
        (else #f)))
(define (opcodes-of m)
  (let z ((i 0)) (when (< i 2048) (%mem-i32-set! (+ CMD (* 4 i)) SENT) (z (+ i 1))))
  (cmd-region! CMD (+ CMD 65536))
  (cmd-begin!)
  (let ((h (fx-mesh! m)))
    (fx-mesh-use! prog h)
    (fx-mesh-draw! h))
  (let walk ((p CMD) (acc '()))
    (let ((w (%mem-i32-ref p)))
      (cond ((= w SENT) (reverse acc))
            ((arity w) => (lambda (n) (walk (+ p 4 (* 4 n)) (cons w acc))))
            (else (list 'UNKNOWN-OPCODE w 'after (reverse acc)))))))

;; 257 x 257 = 66049 vertices, one past the 65536 the predicate names
(define big (mesh-heightmap 4.0 4.0 256 256 (lambda (x z) 0.0)))
(define small (mesh-heightmap 4.0 4.0 4 4 (lambda (x z) 0.0)))

(want 'g02-SETUP-big-is-u32 (mesh-index-u32? big) #t)
(want 'g02-SETUP-small-is-u16 (mesh-index-u32? small) #f)

;; ---- red ----
;; the whole stream, so a wrong operand table shows up as an unknown
;; opcode rather than as a plausible answer
(want 'g02-big-mesh-stream (opcodes-of big) '(2 27 16 4 36 37))

;; ---- controls ----
(want 'g02-CONTROL-small-mesh-stream (opcodes-of small) '(2 27 16 4 17 18))
(want 'g02-CONTROL-boundary-65536
      (mesh-index-u32? (mesh-heightmap 1.0 1.0 255 255 (lambda (x z) 0.0)))
      #f)

(if (null? fails) (display #t) (begin (display fails) (newline)))
