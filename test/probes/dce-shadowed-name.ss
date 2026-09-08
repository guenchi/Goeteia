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

;; A name defined twice at the top level makes dead-code elimination
;; drop what only the FIRST definition calls, while keeping both
;; definitions to compile.  Compiling this file fails, on both
;; targets, with
;;
;;   at test/probes/dce-shadowed-name.ss:22 (use)
;;   Exception in goeteia: cannot call: bye
;;
;; `bye' is reachable only from the first `use'.  prune-dead builds
;; one table entry per NAME, so the second definition is the one whose
;; references are followed, and `bye' is never marked live; the filter
;; that keeps forms then asks only whether the NAME is live, so the
;; first `use' is emitted anyway and its call has no callee left.
;;
;; The shape reaches real programs through libraries, which the driver
;; inlines into the same top level: a program that defines `root' next
;; to (web reactive)'s `root' pruned that library's dispose path out
;; from under it.  A program file is the smallest statement of it.
(import (rnrs))
(define (bye) (display 'gone) (newline))
(define (use) (bye))
(define use 1)
(display use) (newline)
