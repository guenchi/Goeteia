// A walker over the wasm this compiler emits: sections, the name section,
// function bodies, and every instruction with its immediates skipped.
// It exists so a product cell can ask a STRUCTURAL question of one named
// function -- how many raw f64 locals, how many times it boxes -- instead
// of searching bytes, where an immediate can look like an opcode and a
// boxed path still contains the arithmetic (design §5.2).
//
// Its own known answer is walkClean(): every body in the module must be
// consumed exactly and end on `end'.  A wrong immediate table desyncs on
// some function and fails that.  On the module the product cells use it
// is 145 of 145.
export function readModule(bytes) {
    const u8 = new Uint8Array(bytes);
    let p = 8;
const leb = () => { let r = 0, s = 0, x; do { x = u8[p++]; r |= (x & 127) << s; s += 7; } while (x & 128); return r >>> 0; };
    const sleb = () => { let r = 0, s = 0, x; do { x = u8[p++]; r |= (x & 127) << s; s += 7; } while (x & 128); return r; };
    const str = () => { const n = leb(); const t = new TextDecoder().decode(u8.subarray(p, p + n)); p += n; return t; };
    let names = new Map(), bodies = [], nImports = 0;
    while (p < u8.length) {
        const id = u8[p++], len = leb(), end = p + len;
        if (id === 2) { const n = leb(); for (let i = 0; i < n; i++) { str(); str(); const k = u8[p++]; if (k === 0) { leb(); nImports++; } else if (k === 1) { p++; const f = leb(); if (f & 1) leb(); } else if (k === 2) { const f = u8[p++]; leb(); if (f & 1) leb(); } else { p++; p++; } } p = end; }
        else if (id === 10) { const n = leb(); for (let i = 0; i < n; i++) { const sz = leb(); bodies.push([p, p + sz]); p += sz; } p = end; }
        else if (id === 0) { const nm = str(); if (nm === 'name') { while (p < end) { const sub = u8[p++], slen = leb(), send = p + slen; if (sub === 1) { const n = leb(); for (let i = 0; i < n; i++) { const idx = leb(); names.set(idx, str()); } } p = send; } } p = end; }
        else p = end;
    }
    // --- immediates ---
    function blocktype() { const b = u8[p]; if (b === 0x40 || (b >= 0x6a && b <= 0x7f)) { p++; return; } if (b === 0x63 || b === 0x64) { p++; leb(); return; } sleb(); }
    function heaptype() { const b = u8[p]; if (b >= 0x69 && b <= 0x7f) { p++; return; } sleb(); }
    function walk(start, end) {
        p = start; const ngroups = leb(); const locals = [];
        for (let i = 0; i < ngroups; i++) { const n = leb(); const t = u8[p++]; if (t === 0x63 || t === 0x64) heaptype(); locals.push([n, t]); }
        const ops = []; let last = -1;
        while (p < end) {
            const op = u8[p++]; last = op; ops.push(op);
            if (op === 0x02 || op === 0x03 || op === 0x04) blocktype();
            else if (op === 0x0c || op === 0x0d) leb();
            else if (op === 0x0e) { const n = leb(); for (let i = 0; i <= n; i++) leb(); }
            else if (op === 0x10 || op === 0x12) leb();
            else if (op === 0x11 || op === 0x13) { leb(); leb(); }
            else if (op === 0x14 || op === 0x15) leb();
            else if (op === 0x1c) { const n = leb(); for (let i = 0; i < n; i++) p++; }
            else if (op >= 0x20 && op <= 0x24) leb();
            else if (op >= 0x28 && op <= 0x3e) { leb(); leb(); }
            else if (op === 0x3f || op === 0x40) p++;
            else if (op === 0x41) sleb();
            else if (op === 0x42) sleb();
            else if (op === 0x43) p += 4;
            else if (op === 0x44) p += 8;
            else if (op === 0xd0) heaptype();
            else if (op === 0xd2) leb();
            else if (op === 0xd5 || op === 0xd6) leb();
            else if (op === 0xfb) { const sub = leb(); ops.push(0xfb00 | sub);
                if (sub === 0x14 || sub === 0x15) heaptype();               // ref.test / ref.cast (nullable variants 0x15/0x17)
                else if (sub === 0x16 || sub === 0x17) heaptype();
                else if (sub === 0x18 || sub === 0x19) { p++; leb(); heaptype(); heaptype(); }   // br_on_cast
                else if (sub === 0x1a || sub === 0x1b || sub === 0x1c || sub === 0x1d || sub === 0x1e) {}  // any.convert_extern, extern.convert_any, ref.i31, i31.get_s, i31.get_u
                else if (sub >= 0x00 && sub <= 0x0c) { leb(); if (sub === 0x02 || sub === 0x03 || sub === 0x04 || sub === 0x05) leb(); if (sub === 0x0b || sub === 0x0c) leb(); }
                else if (sub === 0x0d) { leb(); leb(); }                     // array.new_data / fill-ish
                else if (sub === 0x0e || sub === 0x0f) { leb(); leb(); }
                else if (sub === 0x10) leb();
                else if (sub === 0x11 || sub === 0x12 || sub === 0x13) { leb(); leb(); }
            }
            else if (op === 0xfc) { const sub = leb(); ops.push(0xfc00 | sub); if (sub <= 7) {} else if (sub === 8) { leb(); leb(); } else if (sub === 9) leb(); else if (sub === 10) { leb(); leb(); } else if (sub === 11) leb(); else { leb(); leb(); } }
            else if (op === 0xfd) { leb(); }
        }
        return { locals, ops, clean: p === end && last === 0x0b };
    }
    
    const fnByName = (want) => { const e = [...names].find(([, n]) => n === want); return e ? bodies[e[0] - nImports] : null; };
    const inspect = (want) => {
        const b = fnByName(want); if (!b) return null;
        const r = walk(b[0], b[1]); const hist = {};
        for (const o of r.ops) hist[o] = (hist[o] || 0) + 1;
        return { clean: r.clean, ops: r.ops.length,
                 f64Locals: r.locals.filter(([, t]) => t === 0x7c).reduce((a, [n]) => a + n, 0),
                 count: (op) => hist[op] || 0 };
    };
    const walkClean = () => { let c = 0; for (const [s, e] of bodies) if (walk(s, e).clean) c++; return [c, bodies.length]; };
    return { names, bodies, nImports, walk, inspect, walkClean };
}
export const OP = { 'f64.add': 0xa0, 'f64.mul': 0xa2, 'call': 0x10, 'struct.new': 0xfb00, 'struct.get': 0xfb02, 'ref.cast': 0xfb16 };
