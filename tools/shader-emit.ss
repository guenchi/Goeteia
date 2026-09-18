;; expect: #t
;; Print every shader this tree can emit, so that something outside
;; Scheme can hand them to a real GLSL compiler.
;;
;; This is not a test -- it is the first half of
;; test/shader-compile.mjs, which runs it and compiles what it prints.
;;
;; It lives in tools/ and not in test/ because in test/ a program's whole
;; stdout IS its verdict: this one printed twenty-two shaders where the
;; runner expected `#t`, and failed on all three targets.  That is the
;; same trap that made a test's own stand-down announcement fail it
;; earlier the same night, in a second form: a directory where printing
;; is the answer is no place for a program whose job is to print.
;;
;; The last entry is deliberately invalid.  Without it, "everything
;; compiled" could also mean the compiler was never reached: the page
;; verifier's GL answers true to every shader it is shown, so a run
;; against a stub would look identical to a run against a compiler.
(import (rnrs) (gfx glsl) (gfx surface)
        (gfx fx) (gfx ibl) (gfx post) (gfx sprite) (gfx scene)
        (gfx mat) (gfx lod)
        (gfx gltf) (gfx mesh) (gfx particles))

(define (render dialect forms)
  (cond ((not forms) "")
        ((string=? dialect "es300") (glsl300-fs->string forms))
        (else (glsl->string forms))))
(define (render-vs dialect forms)
  (cond ((not forms) "")
        ((string=? dialect "es300") (glsl300-vs->string forms))
        (else (glsl->string forms))))

(define (emit! lib rows)
  (for-each
   (lambda (row)
     (let ((name (car row)) (dialect (symbol->string (cadr row)))
           (vs (caddr row)) (fs (cadddr row)))
       (display "=== ") (display lib) (display "/") (display name)
       (display " ") (display dialect) (newline)
       (display "--- vertex ---") (newline)
       (display (render-vs dialect vs)) (newline)
       (display "--- fragment ---") (newline)
       (display (render dialect fs)) (newline)))
   rows))

;; A function set is not a program, so a real compiler cannot read one
;; on its own.  Wrapping it in the smallest program that CALLS every
;; function is stronger than compiling the text would have been,
;; because the call sites make the compiler check the SIGNATURES.
;;
;; This comment used to add "and a function nobody calls is dead code a
;; driver is free to discard before it ever looks at the body", and that
;; half was wrong.  Measured against the compiler this tree actually
;; uses, with nothing calling the function: a call to an undefined
;; function, a reference to an undeclared identifier, a dimension
;; mismatch, and an int declared from a float literal were all four
;; refused, each with a line number.  A body is checked whether or not
;; it is reached.
;;
;; So what a call site buys is precise, and it is the part no other
;; check here covers: a parameter list nothing calls is a parameter list
;; nothing has ever disagreed with.
;; The dialect is a parameter because derivatives are not in every
;; one: dFdx and dFdy are core in ES 3.00 and need
;; GL_OES_standard_derivatives in ES 1.00, and a set that uses them
;; compiled here as es100 fails on a real compiler with "no matching
;; overloaded function" -- which is the emitter doing its job.
(define (emit-functions! lib fns calls . dialect)
  (emit! lib
         (list (list "functions" (if (pair? dialect) (car dialect) 'es100)
                     '((attribute vec2 a_pos)
                       (define (main) void
                         (set! gl_Position (vec4 a_pos (fl 0) (fl 1)))))
                     (append '((precision highp float)) fns
                             (list (list 'define '(main) 'void
                                         (list 'set! 'gl_FragColor calls))))))))

(emit! "fx" (fx-quad-shaders))
(emit! "ibl" (ibl-shaders))
(emit! "post" (post-shaders))
(emit! "sprite" (sprite-shaders))
(emit! "scene" (scene-shaders))
(emit! "gltf" (gltf-shaders))
(emit-functions! "mat" (mat-shader-functions)
                 '(vec4 (safe_unit (vec3 (fl 1) (fl 2) (fl 2)))
                        (dot (rot_axis (vec3 (fl 1) (fl 0) (fl 0))
                                       (vec3 (fl 0) (fl 1) (fl 0)))
                             (vec3 (fl 1) (fl 1) (fl 1)))))
(emit-functions! "lod" (lod-shader-functions)
                 '(vec4 (lod_interval (fl 5) (fl 1) (vec2 (fl 1) (fl 2))
                                      (vec2 (fl 3) (fl 4)) (fl 1))
                        (dither_threshold gl_FragCoord.xy)
                        (fl 1)))
;; EVERY function in the set is called from main, and that is the point
;; of the calls expression rather than a flourish: an uncalled function
;; is one whose PARAMETER LIST nothing has ever disagreed with, and
;; registering a set without reaching all of it checks every body and no
;; signature. The bodies are covered either way -- see the paragraph
;; below, which is a reading and not a belief. The sampler is declared
;; here because triplanar_color takes one, and it rides in front of the
;; function list so it lands after the precision line.
;;
;; What a call buys, measured against ANGLE rather than assumed: a body
;; is checked whether or not anything calls it, and a call adds exactly
;; two objections, to the TYPES and to the ARITY. Transposing two
;; parameters of DIFFERENT types is refused; adding one is refused;
;; transposing two parameters of the SAME type compiles, with the call
;; left untouched, and returns the wrong number in silence. No argument
;; list can buy that one back, because a call site compares types and
;; never values.
;;
;; So the distinct values here are not for the compiler. They are for
;; anything that DRAWS these -- a transposition shows up in the pixels
;; only where the two arguments differ, and an argument list that
;; passed 1.0 twice would hide it there too. Seven of these lists
;; passed a repeated value when first written.
;;
;; water_shore_foam's depth is 0.15 and not something rounder because
;; the function returns before its body on a depth at or past
;; band + max(footprint, 0.001), which is 0.35 here. The first version
;; passed 0.5 and every pixel took that branch, so the call reached the
;; function and computed nothing -- reachable and dead at once. The
;; arithmetic: smoothstep(0, 0.1, 0.5) is 1, smoothstep(0.0625, 0.35,
;; 0.5) is 1, so contact is 0. At 0.15 contact is 0.78.
;;
;; The two bump vectors are 0.61, 0.38, 0.92 and not 0.5, 0.5, 1.0 for
;; the same kind of reason, one layer further in. apply_normal_map turns
;; a bump into bump*2-1, so 0.5, 0.5, 1.0 is exactly the z axis, and the
;; caller normalises what comes back -- which removes everything an
;; axis-aligned vector can carry about the basis it was multiplied by.
;; tangent_frame was therefore reached and could not affect the result:
;; perturbing its entire body left the drawn frame identical. Off the
;; axis it contributes again. Only these two occurrences are bumps; the
;; same triple appears as other arguments elsewhere and means something
;; else there.
(emit-functions! "surface" (append '((uniform sampler2D u_surface_tex))
                                   (mat-shader-functions)
                                   (surface-shader-functions))
                 '(vec4 (+ (surface_normal (vec3 (fl 0) (fl 1) (fl 0))
                                           (vec3 gl_FragCoord.x gl_FragCoord.y (fl 0))
                                           gl_FragCoord.xy
                                           (vec3 (fl 0 61) (fl 0 38) (fl 0 92))
                                           (fl 1)
                                           (?: (> gl_FragCoord.x (fl 0)) true false))
                           (triplanar_color u_surface_tex
                                           (vec3 gl_FragCoord.x gl_FragCoord.y (fl 0))
                                           (vec3 (fl 0 5) (fl 0 25) (fl 0 25)))
                           (triplanar_normal (vec3 (fl 0) (fl 1) (fl 0))
                                            (vec3 (fl 0 5) (fl 0 5) (fl 1))
                                            (vec3 (fl 0 6) (fl 0 4) (fl 0 9))
                                            (vec3 (fl 0 45) (fl 0 55) (fl 0 8))
                                            (vec3 (fl 0 5) (fl 0 25) (fl 0 25)))
                           (surface_tangent (vec3 gl_FragCoord.x gl_FragCoord.y (fl 0))
                                           gl_FragCoord.xy
                                           (vec3 (fl 0) (fl 1) (fl 0)))
                           (skin_diffuse (vec3 (fl 0) (fl 1) (fl 0))
                                        (vec3 (fl 0 6) (fl 0 8) (fl 0))
                                        (vec3 (fl 0 5) (fl 0 5) (fl 1)))
                           (leaf_transmission (vec3 (fl 0 5) (fl 0 5) (fl 1))
                                             (vec3 (fl 0) (fl 0) (fl 1))
                                             (vec3 (fl 0 6) (fl 0 8) (fl 0))
                                             (vec3 (fl 0) (fl 1) (fl 0))
                                             gl_FragCoord.x)
                           (water_transmission (vec3 (fl 0 5) (fl 0 5) (fl 1))
                                              (vec3 (fl 0 2) (fl 0 4) (fl 0 6))
                                              (vec3 (fl 0 1) (fl 0 2) (fl 0 3))
                                              gl_FragCoord.x)
                           (ambient_diffuse (vec3 (fl 0 5) (fl 0 5) (fl 1))
                                           (fl 0 5)
                                           (vec3 (fl 0) (fl 1) (fl 0))
                                           (vec3 (fl 0 2) (fl 0 2) (fl 0 2))
                                           (vec3 (fl 0 6) (fl 0 7) (fl 0 9))))
                        (+ (dot (apply_normal_map
                                 (tangent_frame (vec3 (fl 0) (fl 1) (fl 0))
                                                (vec3 gl_FragCoord.x gl_FragCoord.y (fl 0))
                                                gl_FragCoord.xy
                                                true)
                                 (vec3 (fl 0 61) (fl 0 38) (fl 0 92))
                                 (fl 1))
                                (vec3 (fl 1) (fl 1) (fl 1)))
                           (fiber_specular (vec3 (fl 1) (fl 0) (fl 0))
                                          (vec3 (fl 0) (fl 1) (fl 0))
                                          (fl 0 5))
                           (cloth_sheen (vec3 (fl 0) (fl 1) (fl 0))
                                       (vec3 (fl 0) (fl 0) (fl 1))
                                       (vec3 (fl 0 6) (fl 0 8) (fl 0)))
                           (filtered_roughness (vec3 (fl 0) (fl 1) (fl 0)) (fl 0 5))
                           (surface_height_blend gl_FragCoord.x (fl 0 5) (fl 0 3) (fl 0 1))
                           (shore_wetness gl_FragCoord.x (fl 0 5) (fl 0 25))
                           (water_path_length (vec3 gl_FragCoord.x (fl 2) (fl 0))
                                            (vec3 (fl 0) (fl 0) (fl 0))
                                            (fl 1))
                           (water_foam_hash gl_FragCoord.xy)
                           (water_foam_noise gl_FragCoord.xy)
                           (water_shore_foam gl_FragCoord.xy (fl 0 15) (fl 0 1)
                                             gl_FragCoord.x (fl 0 25))
                           (dot (rot_axis (vec3 (fl 1) (fl 0) (fl 0))
                                          (vec3 (fl 0) (fl 1) (fl 0)))
                                (vec3 (fl 1) (fl 1) (fl 1)))))
                 'es300)

(emit! "mesh" (mesh-shaders))
(emit! "particles" (particles-shaders))

;; the control: a vertex shader a real compiler must refuse
(display "=== control/known-bad es100") (newline)
(display "--- vertex ---") (newline)
(display (glsl->string '((define (main) void (local int n (fl 1 0)))))) (newline)
(display "--- fragment ---") (newline)
(newline)
(display #t)
