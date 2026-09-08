// Copyright 2026 guenchi
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// What a goeteia program hands its host when it dies.
//
// The prelude writes "unhandled exception: who: message irritants"
// through io.write_byte and THEN traps, so by the time a host sees the
// trap the useful half is already sitting in the output buffer --
// dropping it is what left an embedder with nothing but
// `RuntimeError: unreachable`.  Both runners build their rejection
// here so the rule has one implementation: the message is the
// program's exception line with the trap appended, `output` is
// everything the program wrote, `cause` is the trap itself.  A program
// that trapped without announcing anything (a stack overflow) has no
// such line, and keeps the trap's own text as the message.
//
// The line is recognized in the program's own output, so a program
// that prints one of its own is indistinguishable from the prelude's.
// Taking the LAST match is what settles that: the prelude writes after
// the program, so a real exception line always wins over an earlier
// impostor.  A program that fakes one and then dies un-announced does
// get its fake reported -- deliberately not defended against, since
// the only cost is a misleading message on a program built to mislead.
//

export function programFailure(cause, text) {
    const PREFIX = 'unhandled exception: ';
    const line = text.split('\n').filter(l => l.startsWith(PREFIX)).pop();
    const trap = cause && cause.message ? cause.message : String(cause);
    const err = new Error(
        line === undefined ? trap : `${line.slice(PREFIX.length)} (trap: ${trap})`,
        { cause });
    err.output = text;
    return err;
}
