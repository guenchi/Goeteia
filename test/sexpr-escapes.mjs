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

test('a hex escape inside a symbol reads back', () => {
    for (const row of table.symbols) {
        const v = read(row.src);
        assert.equal(v[row.sym_index].name, row.want_symbol, row.src);
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
