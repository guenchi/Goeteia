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

;; An orbit camera: a point it looks at, an angle and a distance it
;; watches from, and an eye that follows rather than snaps.
;;
;;   (define c (make-orbit-camera))
;;   ;; the eye height in the anchor is the CALLER's, not ours
;;   (camera-target! c (v3 0.0 1.55 0.0))
;;   (camera-orbit! c dyaw dpitch 0.0)
;;   (camera-follow! c dt)
;;   (fx-uniform! prog 'u_view (camera-view c))
;;
;; THERE ARE TWO LOOK POINTS AND THEY ARE NOT INTERCHANGEABLE.
;; camera-target! sets the GOAL -- where the camera should be looking.
;; camera-aim reads it back unchanged.  camera-target answers the
;; SMOOTHED point, which follows the goal at the same rate the eye
;; follows its own, and which is what camera-view looks at.
;;
;; The smoothed one is for what is SEEN: the view matrix, and anything
;; composed around the gaze.  The raw one is for what is COMPUTED:
;; which detail level to load something at, what to stream in, where a
;; thing is for the purpose of reacting to it.  The smoothed point sits
;; behind the anchor by a distance that grows with speed, so a world
;; keyed to it loads late exactly when the anchor is moving fast -- the
;; moment it needed to be early -- and anything that moves aside for
;; the camera moves aside in the wrong place.  Neither mistake raises.
;;
;; Both being damped at one rate is what keeps the heading steady.  The
;; two goals differ by the orbit offset, damping is affine, so the pair
;; stays exactly that offset apart once it is -- whatever the frame
;; times are.  camera-place! exists to establish that at a cut, and
;; camera-follow! does it on the first step.
;;
;; What this library does NOT decide, on purpose:
;;
;;   * mouse sensitivity.  camera-orbit! takes the change already in
;;     radians and world units.  A pixels-per-radian factor belongs to
;;     the input layer, and burning one in here would make every caller
;;     with a different device divide it back out.
;;   * how high above a character the target sits.  That is the
;;     character's eye height; pass a target that already includes it.
;;   * whether the world has ground at all.  camera-floor! takes a
;;     function, and #f means there is none.
;;
;; The limits have gentle defaults so that a camera works before it is
;; configured, but they are values, not constants: camera-limits! sets
;; them and refuses a reversed pair by name.
(library (gfx camera)
  (export make-orbit-camera orbit-camera?
          camera-yaw camera-pitch camera-distance
          camera-limits! camera-orbit! camera-target! camera-follow!
          camera-floor! camera-shake! camera-place!
          camera-eye camera-target camera-aim camera-view)
  (import (rnrs) (gfx mat))

  (define ($cam-fl v) (if (flonum? v) v (exact->inexact v)))

  (define-record-type ($camera $make-camera orbit-camera?)
    (fields (mutable yaw $cam-yaw $cam-yaw!)
            (mutable pitch $cam-pitch $cam-pitch!)
            (mutable dist $cam-dist $cam-dist!)
            (mutable pitch-lo $cam-plo $cam-plo!)
            (mutable pitch-hi $cam-phi $cam-phi!)
            (mutable dist-lo $cam-dlo $cam-dlo!)
            (mutable dist-hi $cam-dhi $cam-dhi!)
            (mutable aim $cam-aim $cam-aim!)
            (mutable target $cam-target $cam-target!)
            (mutable eye $cam-eye $cam-eye!)
            (mutable placed $cam-placed $cam-placed!)  ; has the eye ever been put?
            (mutable floor-fn $cam-floor $cam-floor!)
            (mutable clearance $cam-clear $cam-clear!)
            (mutable shake $cam-shake $cam-shake!)
            (mutable follow-rate $cam-follow-rate $cam-follow-rate!)
            (mutable shake-rate $cam-shake-rate $cam-shake-rate!)
            (mutable shake-max $cam-shake-max $cam-shake-max!)))

  (define (make-orbit-camera)
    ($make-camera 0.0 0.35 6.0
                  0.08 1.12          ; pitch, radians: never underneath,
                  1.0 30.0           ; never straight down
                  (v3 0.0 0.0 0.0) (v3 0.0 0.0 0.0) (v3 0.0 0.0 0.0) #f
                  #f 0.0
                  (v3 0.0 0.0 0.0)
                  12.0 8.0 1.0))

  (define (camera-yaw c) ($cam-yaw c))
  (define (camera-pitch c) ($cam-pitch c))
  (define (camera-distance c) ($cam-dist c))
  ;; Two look points, and which one a caller wants depends on what it
  ;; is for.  See the note above camera-target! -- the distinction is
  ;; the point of this pair and getting it wrong is silent.
  (define (camera-target c) ($cam-target c))
  (define (camera-aim c) ($cam-aim c))

  ;; A reversed pair is refused by name rather than quietly swapped: a
  ;; caller that passed them the wrong way round has a bug in the code
  ;; that computed them, and silently sorting the pair hides it until
  ;; the numbers are far enough apart to matter.
  (define (camera-limits! c pitch-lo pitch-hi dist-lo dist-hi)
    (let ((plo ($cam-fl pitch-lo)) (phi ($cam-fl pitch-hi))
          (dlo ($cam-fl dist-lo)) (dhi ($cam-fl dist-hi)))
      (unless (fl<? plo phi)
        (error 'camera-limits! "the pitch limits are reversed" plo phi))
      (unless (fl<? dlo dhi)
        (error 'camera-limits! "the distance limits are reversed" dlo dhi))
      (when (fl<? dlo 0.0)
        (error 'camera-limits! "a distance limit may not be negative" dlo))
      ($cam-plo! c plo) ($cam-phi! c phi)
      ($cam-dlo! c dlo) ($cam-dhi! c dhi)
      ;; the current values are brought inside the new limits at once,
      ;; so a caller cannot observe a camera outside its own bounds
      ($cam-pitch! c (fl-clamp ($cam-pitch c) plo phi))
      ($cam-dist! c (fl-clamp ($cam-dist c) dlo dhi))))

  ;; yaw is NOT clamped and NOT folded into a turn.  It is an
  ;; accumulated heading, and folding it would erase the fact that the
  ;; player spun three times.  There is no seam to worry about because
  ;; the damping below happens in POSITION space, not in angle space --
  ;; fl-turn is right next door and its name fits, but the problem it
  ;; solves does not arise here.  Having a tool to hand is not a reason
  ;; to use it.
  (define (camera-orbit! c dyaw dpitch ddist)
    ($cam-yaw! c (fl+ ($cam-yaw c) ($cam-fl dyaw)))
    ($cam-pitch! c (fl-clamp (fl+ ($cam-pitch c) ($cam-fl dpitch))
                             ($cam-plo c) ($cam-phi c)))
    ($cam-dist! c (fl-clamp (fl+ ($cam-dist c) ($cam-fl ddist))
                            ($cam-dlo c) ($cam-dhi c))))

  ;; WHAT THIS SETS IS THE GOAL, NOT THE CURRENT LOOK POINT.  The look
  ;; point follows it the way the eye follows: a caller writing this
  ;; every simulation step gets a look point that moves smoothly between
  ;; those steps instead of stepping with them.
  ;;
  ;; That is the whole reason the two are separate.  A simulation writes
  ;; a new anchor at its own fixed rate while the display draws faster;
  ;; if the look point were this value outright, the heading -- the
  ;; difference between the eye, which IS smoothed, and the look point,
  ;; which would not be -- would jump on the frames carrying a
  ;; simulation step and sit still on the others.  Nothing about that
  ;; reads as a bug at the call site: every value written is correct,
  ;; and the picture still wobbles.
  ;;
  ;; ANYTHING THAT COMPUTES RATHER THAN LOOKS WANTS camera-aim.  The
  ;; smoothed point is behind the thing it is following, by design and
  ;; by a distance that grows with speed.  Use it for what the viewer
  ;; sees -- the view matrix, a sky or reflection composed around the
  ;; gaze.  Do not use it to decide what to load, what detail to load it
  ;; at, or where something is for the purpose of interacting with it:
  ;; streaming keyed to a point that lags arrives late exactly when the
  ;; anchor is moving fast, which is when it had to be early, and a
  ;; world that reacts to the lagged point reacts in the wrong place.
  (define (camera-target! c v) ($cam-aim! c v))

  (define (camera-floor! c floor-fn clearance)
    ($cam-floor! c floor-fn)
    ($cam-clear! c ($cam-fl clearance)))

  ;; An impulse, added to whatever shake is already decaying, and
  ;; clamped so that a stack of hits in one frame cannot throw the eye
  ;; across the level.  power scales the impulse; the clamp is on the
  ;; result, so it bounds the whole accumulation and not each addend.
  (define (camera-shake! c dx dy dz power)
    (let* ((s ($cam-shake c))
           (k ($cam-fl power))
           (m ($cam-shake-max c))
           (nx (fl-clamp (fl+ (v3-x s) (fl* ($cam-fl dx) k)) (fl- 0.0 m) m))
           (ny (fl-clamp (fl+ (v3-y s) (fl* ($cam-fl dy) k)) (fl- 0.0 m) m))
           (nz (fl-clamp (fl+ (v3-z s) (fl* ($cam-fl dz) k)) (fl- 0.0 m) m)))
      ($cam-shake! c (v3 nx ny nz))))

  ;; Where the eye WOULD sit, ignoring the follow: on a sphere of the
  ;; current radius around the AIM -- not around the smoothed look
  ;; point -- at the current yaw and pitch.
  ;;
  ;; Which of the two it orbits is not a detail.  Both the eye and the
  ;; look point are damped, at one rate, and damping is affine: if two
  ;; quantities start a fixed distance apart and are damped toward goals
  ;; that same distance apart, they stay exactly that distance apart,
  ;; whatever the step lengths are and however the goal moves.  Orbiting
  ;; the aim is what makes the eye's goal and the look point's goal
  ;; differ by exactly the orbit offset, so the rig stays rigid and the
  ;; heading is constant.  Orbiting the smoothed point instead feeds the
  ;; look point's own lag back into the eye's goal, and then the
  ;; separation depends on how long each step was -- which is to say the
  ;; heading wobbles with the frame times, which is the defect this
  ;; whole arrangement exists to remove.
  (define ($cam-desired c)
    (let* ((t ($cam-aim c))
           (d ($cam-dist c))
           (cp (flcos ($cam-pitch c)))
           (sp (flsin ($cam-pitch c)))
           (sy (flsin ($cam-yaw c)))
           (cy (flcos ($cam-yaw c))))
      (v3 (fl+ (v3-x t) (fl* d (fl* cp sy)))
          (fl+ (v3-y t) (fl* d sp))
          (fl+ (v3-z t) (fl* d (fl* cp cy))))))

  ;; One step of following.  The damping is per unit time (fl-damp), so
  ;; sixty steps of 1/60 land where six steps of 1/6 land -- that is a
  ;; property a test can check, whereas "looks smooth" is not.
  ;;
  ;; ORDER MATTERS: the eye is damped first and lifted above the ground
  ;; afterwards.  Lifting the target of the damping instead would let
  ;; the eye travel toward a point below the ground and climb out of it
  ;; at a terrain edge -- it would dip into the hillside and crawl back
  ;; out, every time.
  (define (camera-follow! c dt)
    (let ((dt ($cam-fl dt))
          (want ($cam-desired c)))
      ;; The first step places both outright: damping from an arbitrary
      ;; origin would fly the camera in from wherever the record
      ;; happened to be initialised.  It is the same act as
      ;; camera-place!, which is why that one is written in terms of
      ;; this flag rather than repeating the two assignments.
      (if (not ($cam-placed c))
          (camera-place! c)
          (let ((e ($cam-eye c))
                (t ($cam-target c))
                (a ($cam-aim c))
                (rate ($cam-follow-rate c)))
            ;; One rate for both, and the look point is moved first so
            ;; that a caller reading camera-target after this call sees
            ;; the point this frame was drawn with.
            ($cam-target! c (v3 (fl-damp (v3-x t) (v3-x a) rate dt)
                                (fl-damp (v3-y t) (v3-y a) rate dt)
                                (fl-damp (v3-z t) (v3-z a) rate dt)))
            ($cam-eye! c (v3 (fl-damp (v3-x e) (v3-x want) rate dt)
                             (fl-damp (v3-y e) (v3-y want) rate dt)
                             (fl-damp (v3-z e) (v3-z want) rate dt)))))
      ;; the ground, after the damping
      (let ((f ($cam-floor c)) (e ($cam-eye c)))
        (when f
          (let ((lowest (fl+ ($cam-fl (f (v3-x e) (v3-z e))) ($cam-clear c))))
            (when (fl<? (v3-y e) lowest)
              ($cam-eye! c (v3 (v3-x e) lowest (v3-z e)))))))
      ;; and the shake decays toward nothing at its own rate
      (let ((s ($cam-shake c)) (rate ($cam-shake-rate c)))
        ($cam-shake! c (v3 (fl-damp (v3-x s) 0.0 rate dt)
                           (fl-damp (v3-y s) 0.0 rate dt)
                           (fl-damp (v3-z s) 0.0 rate dt))))))

  ;; A cut: put the eye and the look point where they belong for the
  ;; aim as it stands, with no travel in between.  This is what the
  ;; first camera-follow! does, and it is exported because the same
  ;; thing has to be available afterwards -- a teleport, a change of
  ;; scene, a jump between fixed viewpoints.  Without it the only way
  ;; to move a camera a long way is to let it fly there, across
  ;; whatever lies between.
  ;;
  ;; It places BOTH.  Placing the eye alone would leave the look point
  ;; travelling to the new anchor from the old one, which is the same
  ;; wrong picture as before with the two halves swapped.
  ;;
  ;; It does NOT clear the shake.  A cut does not un-hit the camera, and
  ;; the shake is a displacement with its own decay that the caller
  ;; asked for; silently dropping it here would make one of the two
  ;; ways of placing a camera quietly different from the other.
  (define (camera-place! c)
    ($cam-target! c ($cam-aim c))
    ($cam-eye! c ($cam-desired c))
    ($cam-placed! c #t))

  ;; the eye a renderer should use: where the follow put it, displaced
  ;; by whatever shake is still ringing
  (define (camera-eye c)
    (let ((e ($cam-eye c)) (s ($cam-shake c)))
      (v3 (fl+ (v3-x e) (v3-x s))
          (fl+ (v3-y e) (v3-y s))
          (fl+ (v3-z e) (v3-z s)))))

  ;; Built from camera-eye and camera-target through m4-look-at, so
  ;; there is one definition of what this camera sees.  A second matrix
  ;; assembled here would be a second answer to the same question, and
  ;; the two would drift.
  (define (camera-view c)
    (m4-look-at (camera-eye c) (camera-target c) (v3 0.0 1.0 0.0))))
