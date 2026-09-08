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

;; Which cell owns a coordinate, in a world that extends both ways.
;;
;; Streaming, spatial hashing and chunked worlds all ask one question --
;; which cell is this point in -- and the naive answer breaks in two
;; places, both of which are silent.
;;
;; The first is the sign.  Truncating toward zero maps -0.5 and 0.5 to
;; the same cell, so cell 0 is twice as wide as every other cell and
;; cell -1 never exists.  Nothing raises; the world simply has one seam
;; where objects pile up and one address that is never loaded.  The cell
;; index is a floor, not a truncation, and the two agree only on the
;; positive side, which is why this survives every test written in the
;; first quadrant.
;;
;; The second is the boundary.  A point exactly on a cell edge must have
;; exactly one owner, or an object sitting on the seam is loaded twice
;; by a streamer that unions cells and zero times by one that partitions
;; them.  Cells are half-open, [origin, origin + size), so a boundary
;; belongs to the cell it opens.  That choice also makes grid-origin an
;; inverse of grid-cell rather than an approximate one: the origin of a
;; cell is always inside that cell.
;;
;; The size is a length, not an index, so it may be any positive number;
;; the index is an exact integer, because callers use it to address
;; something.
;;
;; There is a second implementation of this arithmetic in the tree:
;; lib/gfx/collide.ss keeps a private one for its broad-phase spatial
;; hash.  The two agree today -- both floor -- and neither is derived
;; from the other, which is the whole reason to write this down: if
;; cells here ever stop being uniform, or gain an offset origin, a
;; per-axis size, or any other rule, that copy does NOT follow
;; automatically and the two will disagree silently about which cell a
;; point is in.  Whoever changes the rule here changes it there.
(library (sim grid)
  (export grid-cell grid-origin grid-in-cell?)
  (import (rnrs))

  (define ($grid-fl v) (if (flonum? v) v (exact->inexact v)))

  ;; A size of zero divides, and a negative size mirrors the axis while
  ;; still answering plausible indices, which is worse than dividing.
  ;; NaN fails this test too, since no comparison with it holds.
  (define ($need-size who size)
    (unless (> size 0.0)
      (error who "the cell size must be positive" size)))

  ;; floor, not truncate: this is the whole library.
  (define (grid-cell x size)
    (let ((x ($grid-fl x)) (s ($grid-fl size)))
      ($need-size 'grid-cell s)
      (exact (flfloor (/ x s)))))

  (define (grid-origin i size)
    (unless (and (integer? i) (exact? i))
      (error 'grid-origin "the cell index must be an exact integer" i))
    (let ((s ($grid-fl size)))
      ($need-size 'grid-origin s)
      (* i s)))

  ;; Asked as two independent questions rather than as a rectangle test,
  ;; so it cannot disagree with grid-cell about where a boundary point
  ;; lives -- it is the same answer, compared.
  (define (grid-in-cell? cx cy size x y)
    (let ((s ($grid-fl size)))
      ($need-size 'grid-in-cell? s)
      (and (= (grid-cell x s) cx)
           (= (grid-cell y s) cy)))))
