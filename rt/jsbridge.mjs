// The js.* import bridge shared by every Goeteia host.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

export function makeJsBridge(getExports) {
    let nameBuf = [];
    let argStack = [];
    let staged = [];
    const cbStack = [];
    const takeName = () => {
        const s = String.fromCharCode(...nameBuf);
        nameBuf = [];
        return s;
    };
    const takeArgs = () => {
        const a = argStack;
        argStack = [];
        return a;
    };
    return {
        arg_byte: b => nameBuf.push(b),
        global: () => globalThis,
        get: obj => obj[takeName()],
        set: (obj, v) => { obj[takeName()] = v; },
        push: v => argStack.push(v),
        call: (f, thisv) => f.apply(thisv, takeArgs()),
        new: ctor => new ctor(...takeArgs()),
        string: () => takeName(),
        str_len: s => { staged = [...String(s)].map(c => c.charCodeAt(0) & 0xff); return staged.length; },
        str_byte: i => staged[i],
        number: x => x,
        to_number: v => Number(v),
        eq: (a, b) => (a === b ? 1 : 0),
        bool: v => (v ? 1 : 0),
        undefined: () => undefined,
        fn: closure => (...args) => {
            const frame = { args, ret: undefined };
            cbStack.push(frame);
            try {
                getExports()['$jscb'](closure);
            } finally {
                cbStack.pop();
            }
            return frame.ret;
        },
        cb_argc: () => cbStack[cbStack.length - 1].args.length,
        cb_arg: i => cbStack[cbStack.length - 1].args[i],
        cb_ret: v => { cbStack[cbStack.length - 1].ret = v; },
    };
}

export const jsBridgeStubs = {
    arg_byte: () => {}, global: () => undefined, get: () => undefined,
    set: () => {}, push: () => {}, call: () => undefined,
    new: () => undefined, string: () => '', str_len: () => 0,
    str_byte: () => 0, number: () => 0, to_number: () => 0,
    eq: () => 0, bool: () => 0, undefined: () => undefined,
    fn: () => undefined, cb_argc: () => 0, cb_arg: () => undefined,
    cb_ret: () => {},
};
