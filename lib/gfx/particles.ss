;; Copyright 2026 guenchi
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;; A fixed GPU pool of point sprites: every particle's whole future is
;; written once, and the vertex shader evaluates where it is at time t.
;; Nothing is stepped per frame on the CPU, so ten thousand particles
;; cost one draw call and one upload when something changed.
;;
;;   (define f (make-particles 4096))
;;   (particle-ambient! f x y z r g b size phase)     ; loops forever
;;   (particle-burst! f x y z 40 6.0 r g b 0.8 0.1 9.8)
;;   (particles-clock! f now)                          ; the caller's clock
;;   (particles-draw! f viewproj)
;;
;; The pool is split in two: a reserve at the front for ambient
;; particles that loop forever (dust, embers), and a ring behind it for
;; bursts that are emitted and expire.  The SIZE of that reserve is a
;; parameter, not a constant -- a scene that is all embers and a scene
;; with one campfire want different splits, and the source this came
;; from fixed it at a quarter.
;;
;; Time is the caller's.  particles-clock! sets it and particles-draw!
;; only draws: a fixed-step simulation and a frame-rate render disagree
;; about what "now" is, and a draw call that quietly advanced a clock
;; would give a different answer depending on how often it was called.
(library (gfx particles)
  (export make-particles particles? particles-capacity
          particles-ambient-capacity particles-emitted
          particles-clock! particles-draw!
          particle-emit! particle-ambient! particle-burst!
          particles-vertex-shader particles-fragment-shader)
  (import (rnrs) (gfx fx) (gfx gl) (gfx mat) (sim random))

  (define ($p-fl v) (if (flonum? v) v (exact->inexact v)))

  ;; 13 floats a particle: position 3, velocity 3, colour 3, and a vec4
  ;; of birth, life, size, gravity
  (define $p-floats 13)
  (define $p-stride 52)

  ;; ---- the shaders, which are values a caller can take away ----
  ;;
  ;; They are returned rather than only compiled into a program, so
  ;; that they can be handed to a real GLSL compiler on their own.  The
  ;; page verifier's GL is a stub -- compileShader does nothing and
  ;; getShaderParameter answers true -- so a shader that this library
  ;; emits wrongly would pass every page test.  A shader nobody can
  ;; extract is a shader nobody can check.
  ;;
  ;; They are also written in (gfx glsl) FORMS rather than in strings.
  ;; The source this came from carried whole expressions as bare text
  ;; ("a_life.y < 0.0", "mod(age,duration)"), and text is opaque to
  ;; everything downstream: a constant folded into a uniform cannot be
  ;; substituted into it, and no check can see what it names.
  ;;
  ;; Two shapes needed rewriting rather than transcribing, because this
  ;; DSL has no || and no &&:
  ;;   * the vertex shader's four-way "is this particle dead" test
  ;;     becomes nested ?: over booleans, which is the same expression
  ;;     GLSL's || would build;
  ;;   * the fragment shader's two-way discard becomes two separate if
  ;;     statements, which is clearer than either.
  ;; Neither is a workaround for a missing feature: both say the same
  ;; thing structurally, and both are now visible to a substituter.

  (define (particles-vertex-shader)
    '((attribute vec3 a_pos) (attribute vec3 a_velocity)
      (attribute vec3 a_color) (attribute vec4 a_life)
      (uniform mat4 u_viewproj) (uniform float u_time)
      (uniform float u_height) (uniform float u_size_max)
      (varying vec3 v_radiance) (varying float v_fade)
      (define (main) void
        ;; a negative lifetime marks an ambient particle; its magnitude
        ;; is the loop period
        (local bool ambient (< a_life.y (fl 0)))
        (local float duration (max (abs a_life.y) (fl 0 1 3)))
        (local float age (- u_time a_life.x))
        (if ambient (set! age (mod age duration)))
        (local vec3 p (+ a_pos
                         (* a_velocity age)
                         (vec3 (fl 0)
                               (- (* (fl 0 5) a_life.w age age))
                               (fl 0))))
        ;; ambient particles drift, so that a still scene is not static
        (if ambient
            (set! p (+ p (vec3 (* (sin (+ (* u_time (fl 0 65)) a_pos.x)) (fl 0 5))
                               (* (sin (+ u_time a_pos.z)) (fl 0 28))
                               (* (cos (+ (* u_time (fl 0 4)) a_pos.z)) (fl 0 4))))))
        (local vec4 clip (* u_viewproj (vec4 p (fl 1))))
        (set! v_fade (* (?: ambient (smoothstep (fl 0) (fl 0 8 2) age) (fl 1))
                        (- (fl 1) (smoothstep (* duration (fl 0 35)) duration age))))
        ;; unborn, expired, never emitted, or behind the eye
        (local bool dead
               (?: (< age (fl 0)) true
                   (?: (> age duration) true
                       (?: (== a_life.y (fl 0)) true
                           (< clip.w (fl 0 1))))))
        ;; a dead particle is put outside clip space rather than
        ;; discarded in the fragment stage: it costs nothing there
        (if dead
            (set! clip (vec4 (fl 2) (fl 2) (fl 2) (fl 1)))
            (set! v_fade (fl 0)))
        (set! v_radiance a_color)
        ;; the upper clamp is a uniform, not a literal, so a caller can
        ;; cap point size without relinking -- and so this shader has no
        ;; number in it that belongs to a particular game
        (set! gl_PointSize
              (clamp (/ (* a_life.z u_height) (max clip.w (fl 0 1)))
                     (fl 1) u_size_max))
        (set! gl_Position clip))))

  (define (particles-fragment-shader)
    '((precision highp float)
      (varying vec3 v_radiance) (varying float v_fade)
      (define (main) void
        (local vec2 p (- (* gl_PointCoord (fl 2)) (fl 1)))
        (local float r2 (dot p p))
        ;; two ifs where the source had one `||`
        (if (> r2 (fl 1)) (discard))
        (if (< v_fade (fl 0 1 3)) (discard))
        (local float glow (* (exp (- (* r2 (fl 5))))
                             (- (fl 1) (smoothstep (fl 0 55) (fl 1) r2))
                             v_fade))
        (set! gl_FragColor (vec4 (* v_radiance glow) (fl 1))))))

  ;; ---- the pool ----
  (define-record-type ($particles $make-particles particles?)
    (fields (immutable program $p-program)
            (immutable buffer $p-buffer)
            (immutable base $p-base)
            (immutable capacity particles-capacity)
            (immutable reserve particles-ambient-capacity)
            (immutable size-max $p-size-max)
            (immutable rng $p-rng)
            (mutable next $p-next $p-next!)         ; where the next burst goes
            (mutable used $p-used $p-used!)         ; ambient particles placed
            (mutable dirty $p-dirty $p-dirty!)
            (mutable clock $p-clock $p-clock!)
            (mutable emitted particles-emitted $p-emitted!)))

  ;; capacity, the share of it reserved for ambient particles, and the
  ;; largest a point may be drawn.  Each is refused by name: a caller
  ;; who passed a ratio of 50 meaning "50 percent" has a bug in what
  ;; computed it, and clamping the value would hide it.
  (define (make-particles capacity . opts)
    (let ((ratio (if (pair? opts) ($p-fl (car opts)) 0.25))
          (size-max (if (and (pair? opts) (pair? (cdr opts)))
                        ($p-fl (cadr opts))
                        96.0)))
      (unless (and (integer? capacity) (exact? capacity) (>= capacity 16))
        (error 'make-particles "capacity must be an exact integer of at least 16"
               capacity))
      (unless (and (not (fl<? ratio 0.0)) (not (fl<? 1.0 ratio)))
        (error 'make-particles "the ambient reserve must be a ratio in [0,1]" ratio))
      (unless (fl<? 0.0 size-max)
        (error 'make-particles "the maximum point size must be positive" size-max))
      (let* ((base (fx-alloc! (* capacity $p-stride)))
             (reserve (exact (floor (* capacity (inexact ratio)))))
             (program (fx-program3! (particles-vertex-shader)
                                    (particles-fragment-shader))))
        ;; every particle starts with a zero lifetime, which the shader
        ;; reads as "never emitted" -- so an untouched pool draws
        ;; nothing rather than a cloud at the origin
        (let clear ((i 0))
          (when (< i (* capacity $p-floats))
            (%mem-f32-set! (+ base (* i 4)) 0.0)
            (clear (+ i 1))))
        ($make-particles program (fx-buffer!) base capacity reserve size-max
                         (make-rng 7789) reserve 0 #t 0.0 0))))

  (define (particles-clock! f t) ($p-clock! f ($p-fl t)))

  (define ($p-write! f index row)
    (let put ((i 0))
      (when (< i $p-floats)
        (%mem-f32-set! (+ ($p-base f) (* index $p-stride) (* i 4))
                       ($p-fl (vector-ref row i)))
        (put (+ i 1))))
    ($p-dirty! f #t))

  ;; One particle, born now, on the ring behind the ambient reserve.
  ;; The ring overwrites its oldest entry rather than refusing: a burst
  ;; that arrives when the pool is full should cost the oldest smoke,
  ;; not the new explosion.
  (define (particle-emit! f x y z vx vy vz r g b life size gravity)
    (unless (fl<? 0.0 ($p-fl life))
      (error 'particle-emit! "a particle needs a positive lifetime" life))
    (unless (fl<? 0.0 ($p-fl size))
      (error 'particle-emit! "a particle needs a positive size" size))
    (when (= (particles-ambient-capacity f) (particles-capacity f))
      (error 'particle-emit! "the whole pool is reserved for ambient particles"
             (particles-capacity f)))
    (let ((index ($p-next f)))
      ($p-write! f index
                 (vector x y z vx vy vz r g b ($p-clock f) life size gravity))
      ($p-next! f (if (= (+ index 1) (particles-capacity f))
                      (particles-ambient-capacity f)
                      (+ index 1)))
      ($p-emitted! f (+ 1 (particles-emitted f)))))

  ;; A looping particle in the reserve.  `phase` shifts where in its
  ;; loop it starts, so a field of them does not pulse in unison; the
  ;; negative lifetime is the flag the shader reads.
  (define (particle-ambient! f x y z r g b size phase)
    (let ((index ($p-used f)))
      (when (>= index (particles-ambient-capacity f))
        (error 'particle-ambient! "the ambient reserve is full"
               (particles-ambient-capacity f)))
      ($p-write! f index
                 (vector x y z 0.015 0.025 0.0 r g b
                         (fl- 0.0 ($p-fl phase)) -9.0 size 0.0))
      ($p-used! f (+ index 1))))

  ;; A cone of particles from one point, with speed, lifetime and size
  ;; jittered so that a burst does not look like a stamp.
  (define (particle-burst! f x y z count speed r g b life size gravity)
    (let ((rng ($p-rng f))
          (speed ($p-fl speed)) (life ($p-fl life)) (size ($p-fl size)))
      (let emit ((i 0))
        (when (< i count)
          (let ((angle (random-range! rng 0.0 6.283185307179586))
                (rate (random-range! rng 0.2 1.0)))
            (particle-emit! f x y z
                            (fl* (flsin angle) (fl* speed rate))
                            (random-range! rng 0.1 (fl* speed 0.85))
                            (fl* (flcos angle) (fl* speed rate))
                            r g b
                            (fl* life (random-range! rng 0.6 1.2))
                            (fl* size (random-range! rng 0.6 1.4))
                            gravity))
          (emit (+ i 1))))))

  ;; Draw the pool.  It does not advance anything: the time it renders
  ;; at is whatever particles-clock! was last given.
  (define (particles-draw! f vp)
    (let ((program ($p-program f)))
      (fx-use! program ($p-buffer f))
      (when ($p-dirty f)
        (cmd-bind-buffer! ($p-buffer f))
        (cmd-buffer-data! ($p-base f) (* $p-stride (particles-capacity f)))
        ($p-dirty! f #f))
      (fx-uniform! program 'u_viewproj vp)
      (fx-uniform! program 'u_time ($p-clock f))
      (fx-uniform! program 'u_height ($p-fl (fx-height)))
      (fx-uniform! program 'u_size_max ($p-size-max f))
      (cmd-draw-arrays! GL-POINTS 0 (particles-capacity f)))))
