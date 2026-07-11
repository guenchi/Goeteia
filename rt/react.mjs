// Embedding Goeteia components into a React tree.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.
//
// The Goeteia module registers factories on globalThis.__goeteia
// (see lib/web/react.ss); each is a plain JS function
// (hostElement, props) -> dispose.  This wraps one as a React
// component: React owns a host element, Goeteia owns everything
// under it.
//
//   import { loadGoeteia } from './rt/web.mjs';
//   import { goeteiaComponent } from './rt/react.mjs';
//   loadGoeteia('widgets.wasm');
//   const Counter = goeteiaComponent(React, 'Counter');
//   ... <Counter start={5}/> ...
//
// Props are passed at mount; when a prop value changes the component
// remounts (dispose + fresh mount), which is the natural lifecycle
// for a component whose interior state lives in Goeteia signals.

export function goeteiaComponent(React, name, opts = {}) {
    const tag = opts.tag || 'div';
    return function GoeteiaWrapper(props) {
        const ref = React.useRef(null);
        React.useEffect(() => {
            let dispose, cancelled = false;
            const tryMount = () => {
                if (cancelled) return;
                const reg = globalThis.__goeteia;
                if (reg && reg[name]) dispose = reg[name](ref.current, props);
                else setTimeout(tryMount, 10);      // module still loading
            };
            tryMount();
            return () => { cancelled = true; if (dispose) dispose(); };
        }, Object.values(props));
        return React.createElement(tag, { ref });
    };
}
