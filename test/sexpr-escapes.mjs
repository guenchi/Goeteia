// The reader must accept every string escape a conforming R6RS writer
// emits.  It accepted \n \t \r \" \\ and nothing else, so \a \b \v \f,
// \x<hex>; in a string and \x<hex>; in a symbol were all refused --
// output a standard writer produces could not be read back.  A form
// feed inside a stored value was enough to make that value permanently
// unreadable to a consumer, with nothing reporting a problem.
//
// This is the ACCEPT side only: the writer and test/sexpr-vectors.json
// are deliberately untouched, so not one golden can change colour.
//
// The table lives in test/sexpr-escape-vectors.json and is read by this
// cell AND by test/sexpr-escapes.ss.  One table held against two
// implementations cannot drift; two tables would, and the drift would be
// invisible until a consumer hit the one shape only one of them took.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import url from 'node:url';
import { read } from '../rt/sexpr.mjs';

const here = path.dirname(url.fileURLToPath(import.meta.url));
const table = JSON.parse(fs.readFileSync(path.join(here, 'sexpr-escape-vectors.json'), 'utf8'));
// UTF-8 bytes, not code points: a Goeteia string holds one character per
// byte, so bytes are the one representation both readers can be held to.
const bytesOf = s => Array.from(Buffer.from(s, 'utf8'));

test('every escape a conforming writer emits reads back', () => {
    for (const row of table.accept) {
        const v = read(row.src);
        assert.deepEqual(bytesOf(v[1]), row.bytes,
            `${row.src}  (${row.want})`);
    }
});

// Three assertions per row, failing differently.  The LENGTH catches a
// reader that ran past the escape's semicolon and swallowed the next
// token -- it still reports the right name for the element it built.
// The TYPE catches re-classification: R6RS makes an inline hex escape
// identifier syntax, so \x31; is the symbol named "1", not the number,
// and a reader that decodes then re-classifies answers "1" to a name
// comparison while being wrong about what it returned.  Then the bytes.
test('a hex escape inside a symbol reads back', () => {
    for (const row of table.symbols) {
        const v = read(row.src);
        assert.equal(v.length, row.len, `${row.src}  (${row.want})`);
        const e = v[row.sym_index];
        assert.ok(e !== null && typeof e === 'object' && typeof e.name === 'string',
            `${row.src}: element ${row.sym_index} is not a symbol (${row.want})`);
        assert.deepEqual(bytesOf(e.name), row.bytes, `${row.src}  (${row.want})`);
    }
});

// An escape DISAMBIGUATES a name; it does not EXTEND the character set
// a name may be spelled from.  These decode to a character outside the
// symbol grammar and are refused.  Their discriminating partner is the
// symbols row for \x31;, which decodes to "1" -- a character that IS in
// the grammar, escaped only so it is not read as the number -- and is
// ACCEPTED.  The PAIR discriminates and neither row alone does: refusing
// both is too narrow, accepting both is full R6RS and lets a peer intern
// arbitrary character sequences, accepting ( while refusing 1 is
// incoherent.
//
// This replaces an assertion that the reader refuses exactly the names
// the WRITER refuses.  That was induced from five measured names without
// being checked against the rest of the table, where the \x31; row
// already contradicted it.  It is also self-defeating: this writer emits
// NO escape for any symbol, so "accept only what the writer emits" argues
// for accepting no escapes at all.  These five passed under it by
// coincidence, refused for the character reason and not the writer one.
test('a decoded name outside the symbol grammar is refused', () => {
    for (const row of table.name_outside_grammar) {
        assert.throws(() => read(row.src), undefined, `${row.src}  (${row.why})`);
    }
});

// The widening must not swallow everything after a backslash: a
// misspelled escape has to stay refused, or the accept side would pass
// for a reader that simply stopped checking.
test('a malformed or unknown escape is still refused', () => {
    for (const row of table.reject) {
        assert.throws(() => read(row.src), undefined, `${row.src}  (${row.why})`);
    }
});
