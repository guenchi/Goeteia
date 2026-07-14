// The Why page's typeset effect: why-fx.wasm (built by build.sh from
// why-fx.ss) runs against the live DOM through the standard loader.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.
import { loadGoeteia } from './rt/web.mjs';
loadGoeteia('why-fx.wasm');
