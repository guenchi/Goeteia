"use strict";
const FALSE={s:0},TRUE={s:1},NIL={s:2},VOID={s:3},EOFV={s:4};
class Esc{constructor(p){this.p=p;}}
const PV=x=>{if(x?.t!=='pair')throw new TypeError('expected pair');
return x;};
let IO={write_byte:()=>{},read_byte:()=>-1,path_byte:()=>{},
open_read:()=>-1,open_write:()=>-1,fread:()=>-1,fwrite:()=>{},
fclose:()=>{}};
const W=r=>(((r|0)<<1)<<1)>>1;
const I31=x=>{if(typeof x!=='number'||(x|0)!==x)
throw new TypeError('expected i31');return x;};
const IU=x=>I31(x)>>1;
const S=s=>{const n=s.length,u=new Uint8Array(n);
for(let i=0;i<n;i++)u[i]=s.charCodeAt(i);return u;};
const TD=new TextDecoder(),TE=new TextEncoder();
const U=s=>TD.decode(S(s));
const L2=xs=>{let l=NIL;
for(let i=xs.length-1;i>=0;i--)l={t:"pair",a:xs[i],d:l};return l;};
const LD=(xs,tl)=>{let l=tl;
for(let i=xs.length-1;i>=0;i--)l={t:"pair",a:xs[i],d:l};return l;};
const IC=(f,xs)=>{if(xs.length<f.length)
throw new TypeError('wrong argument count');return f(...xs);};
class TC{constructor(f,xs){this.f=f;this.xs=xs;}}
const TCI=(f,xs)=>{if(xs.length<f.length)
throw new TypeError('wrong argument count');return new TC(f,xs);};
const TR=r=>{while(r instanceof TC)r=r.f(...r.xs);return r;};
const A2=(f,pre,l)=>{const xs=pre;
for(;l!==NIL;l=l.d)xs.push(l.a);return IC(f,xs);};
const A2T=(f,pre,l)=>{const xs=pre;
for(;l!==NIL;l=l.d)xs.push(l.a);return TCI(f,xs);};
const UNR=()=>{throw new Error('unreachable');};
const THR=(tk,v)=>{throw new Esc({t:"pair",a:tk,d:v});};
const KFIX=x=>(typeof x==='number'&&!(x&1))?TRUE:FALSE;
const KCHR=x=>(typeof x==='number'&&(x&1)===1)?TRUE:FALSE;
const KBOOL=x=>(x===TRUE||x===FALSE)?TRUE:FALSE;
const OOB=()=>{throw new RangeError('array element access out of bounds');};
const IX=(a,i)=>{i=IU(i);if(i<0||i>=a.length)OOB();return i;};
const AR=(a,i)=>a[IX(a,i)];
const AW=(a,i,v)=>{a[IX(a,i)]=v;return VOID;};
const STR=x=>{if(!(x instanceof Uint8Array))
throw new TypeError('expected string');return x;};
const VEC=x=>{if(!Array.isArray(x))
throw new TypeError('expected vector');return x;};
class Fl{constructor(v){this.v=v;}}
const FLV=x=>{if(!(x instanceof Fl))
throw new TypeError('expected flonum');return x.v;};
const FB=h=>{const dv=new DataView(new ArrayBuffer(8));
for(let i=0;i<8;i++)dv.setUint8(i,parseInt(h.substr(i*2,2),16));
return dv.getFloat64(0,true);};
const F2I=x=>{x=Math.trunc(x);if(!Number.isFinite(x)||
x<-2147483648||x>2147483647)throw new RangeError('integer overflow');
return W(x);};
class Sym{constructor(s){this.s=s;}}
const SYMV=x=>{if(!(x instanceof Sym))
throw new TypeError('expected symbol');return x;};
class BV{constructor(u){this.u=u;}}
const BVU=x=>{if(!(x instanceof BV))
throw new TypeError('expected bytevector');return x.u;};
class Ratio{constructor(n,dd){this.n=n;this.dd=dd;}}
class Cx{constructor(re,im){this.re=re;this.im=im;}}
class Rec{constructor(f){this.f=f;}}
const KREC=(x,r)=>(x instanceof Rec&&x.f[0]===r)?TRUE:FALSE;
const MEMOBJ=(typeof WebAssembly!=='undefined'&&WebAssembly.Memory)
?new WebAssembly.Memory({initial:1})
:(()=>{let b=new ArrayBuffer(65536);return{get buffer(){return b;},
grow(n){const old=b.byteLength/65536;
const nb=new ArrayBuffer((old+(n>>>0))*65536);
new Uint8Array(nb).set(new Uint8Array(b));b=nb;return old;}};})();
class JSRef{constructor(v){this.v=v;}}
const NB=[],CBS=[];let AS=[],STG=[];
const TDX=()=>{const s=TD.decode(new Uint8Array(NB));NB.length=0;
return s;};
const LG=new Map();
const WASM_SHIM=(typeof WebAssembly!=='undefined')
?new Proxy(WebAssembly,{get:(t,k)=>
(k==='Suspending'||k==='promising')?void 0:Reflect.get(t,k,t)})
:void 0;
const SEV=c=>Function('globalThis','WebAssembly','c','return eval(c);')(GPROX,WASM_SHIM,String(c));
const GPROX=new Proxy(globalThis,{
get(t,k){if(k==='eval')return SEV;
if(k==='WebAssembly')return WASM_SHIM;
if(k==='__goeteia_mem')return MEMOBJ;
if(LG.has(k))return LG.get(k);
return Reflect.get(t,k,t);},
set(t,k,v){if(typeof k==='string'&&k.startsWith('__goeteia_'))
{LG.set(k,v);return true;}
return Reflect.set(t,k,v,t);}});
const JGET=o=>o[TDX()];
const JSET=(o,v)=>{o[TDX()]=v;};
const JCALL=(f,t)=>{const g=AS;AS=[];
return f.apply(t===GPROX?globalThis:t,g);};
const JNEW=c=>{const g=AS;AS=[];return new c(...g);};
const JSL=s=>{STG=TE.encode(String(s));return STG.length;};
let V5,V6,V7,V8,V9,Vb,Vc,Vd,Vf;
const F10=(...v1)=>{const v2=L2(v1);if(v2===NIL){{let v3=(20);return F1f(V7,v3);}}else{return F1f((PV(v2).a),(20));}};
const F11=(v4,...v5)=>{const v6=L2(v5);if(v6===NIL){return F12(v4);}else{return F1g((PV(v6).a),(()=>{return F12(v4);}));}};
const F12=v7=>{B8:for(;;){if((F1r(v7))!==FALSE){return F15(v7);}else{if((KCHR(v7))!==FALSE){{let v9=(I31(v7)&-2);return F1f(V7,v9);}}else{if(v7 instanceof Uint8Array){return F14(v7,(0));}else{if(v7 instanceof Sym){return F14((SYMV(v7).s),(0));}else{if(v7===NIL){(TR((vb=>{return F1f(V7,vb);})(80)));{let vc=(82);return F1f(V7,vc);}}else{if(v7===TRUE){(TR((vd=>{return F1f(V7,vd);})(70)));{let vf=(232);return F1f(V7,vf);}}else{if(v7===FALSE){(TR((vg=>{return F1f(V7,vg);})(70)));{let vh=(204);return F1f(V7,vh);}}else{if((v7.t)==="pair"){(TR((vj=>{return F1f(V7,vj);})(80)));(TR(F11(PV(v7).a)));return F13(PV(v7).d);}else{if((Array.isArray(v7)?TRUE:FALSE)!==FALSE){(TR((vk=>{return F1f(V7,vk);})(70)));(TR((vm=>{return F1f(V7,vm);})(80)));(TR((()=>{{let vn=(0);Bp:for(;;){if(JLTN(vn,(VEC(v7).length<<1))){((JZ(vn))?VOID:(TR((vq=>{return F1f(V7,vq);})(64))));(TR(F12(AR(VEC(v7),vn))));{const vr=(JADD(vn,(2)));vn=vr;continue Bp;}}else{return VOID;}}}})()));{let vs=(82);return F1f(V7,vs);}}else{if(((v7 instanceof BV)?TRUE:FALSE)!==FALSE){(F14(C0,(0)));(TR((()=>{{let vt=(0);Bv:for(;;){if(JLTN(vt,(BVU(v7).length<<1))){((JZ(vt))?VOID:(TR((vw=>{return F1f(V7,vw);})(64))));(TR(F12(AR(BVU(v7),vt)<<1)));{const vz=(JADD(vt,(2)));vt=vz;continue Bv;}}else{return VOID;}}}})()));{let v10=(82);return F1f(V7,v10);}}else{if(((v7 instanceof Rec)?TRUE:FALSE)!==FALSE){(F14(C1,(0)));(TR(F12(PV(v7.f[0]).a)));{let v11=(124);return F1f(V7,v11);}}else{if(typeof v7==='function'){return F14(C2,(0));}else{return F14(C3,(0));}}}}}}}}}}}}}};
const F13=v12=>{B13:for(;;){if(v12===NIL){{let v14=(82);return F1f(V7,v14);}}else{if((v12.t)==="pair"){(TR((v15=>{return F1f(V7,v15);})(64)));(TR(F11(PV(v12).a)));{const v16=(PV(v12).d);v12=v16;continue B13;}}else{(TR((v17=>{return F1f(V7,v17);})(64)));(TR((v18=>{return F1f(V7,v18);})(92)));(TR((v19=>{return F1f(V7,v19);})(64)));(TR(F11(v12)));{let v1b=(82);return F1f(V7,v1b);}}}}};
const F14=(v1c,v1d)=>{B1f:for(;;){if(JLTN(v1d,(STR(v1c).length<<1))){(TR((v1g=>{return F1f(V7,v1g);})(I31((AR(STR(v1c),v1d)<<1)|1)&-2)));{const v1h=v1c,v1j=(JADD(v1d,(2)));v1c=v1h;v1d=v1j;continue B1f;}}else{return VOID;}}};
const F15=v1k=>{B1m:for(;;){if(((v1k instanceof Fl)?TRUE:FALSE)!==FALSE){{let v1n=v1k;if(((FLV(v1n)===FLV(v1n))?FALSE:TRUE)!==FALSE){return F14(C4,(0));}else{return F16(v1n);}}}else{if(((typeof v1k==='bigint')?TRUE:FALSE)!==FALSE){{let v1p=v1k;return F14((S(String(v1p))),(0));}}else{if(((v1k instanceof Ratio)?TRUE:FALSE)!==FALSE){(TR(F15(v1k.n)));(TR((v1q=>{return F1f(V7,v1q);})(94)));{const v1r=(v1k.dd);v1k=v1r;continue B1m;}}else{if(((v1k instanceof Cx)?TRUE:FALSE)!==FALSE){(TR(F15(v1k.re)));(TR((v1s=>{(((TR((v1t=>{if(v1t!==FALSE){return v1t;}else{if(((v1s instanceof Fl)?TRUE:FALSE)!==FALSE){return ((FLV(v1s)<FLV(new Fl(IU(0))))?TRUE:FALSE);}else{return FALSE;}}})(JLTN(v1s,(0))?TRUE:FALSE)))!==FALSE)?VOID:(TR((v1v=>{return F1f(V7,v1v);})(86))));return F15(v1s);})(v1k.im)));{let v1w=(210);return F1f(V7,v1w);}}else{if(JLTN(v1k,(0))){(TR((v1z=>{return F1f(V7,v1z);})(90)));return F18(JSUB((0),v1k));}else{return F18(v1k);}}}}}}};
const F16=v20=>{B21:for(;;){{let v22=(new Fl(IU(0)));{let v23=((FLV(v20)<FLV(v22))?TRUE:FALSE);{let v24=((v23!==FALSE)?(new Fl(FLV(v22)-FLV(v20))):v20);((v23!==FALSE)?(TR((v25=>{return F1f(V7,v25);})(90))):VOID);if(FLV(new Fl(IU(1073741822)))<FLV(v24)){return F14(C5,(0));}else{{let v26=(F2I(v24.v));{let v27=(new Fl(FLV(v24)-FLV(new Fl(IU(v26)))));(TR(F18(v26)));(TR((v28=>{return F1f(V7,v28);})(92)));return F17(v27,(0));}}}}}}}};
const F17=(v29,v2b)=>{B2c:for(;;){if((TR((v2d=>{if(v2d!==FALSE){return v2d;}else{return ((FLV(v29)===FLV(new Fl(IU(0))))?TRUE:FALSE);}})(JEQN(v2b,(24))?TRUE:FALSE)))!==FALSE){if(JZ(v2b)){{let v2f=(96);return F1f(V7,v2f);}}else{return VOID;}}else{{let v2g=(new Fl(FLV(v29)*FLV(new Fl(IU(20)))));{let v2h=(F2I(v2g.v));(TR((v2j=>{return F1f(V7,v2j);})(JADD((96),v2h))));{const v2k=(new Fl(FLV(v2g)-FLV(new Fl(IU(v2h))))),v2m=(JADD(v2b,(2)));v29=v2k;v2b=v2m;continue B2c;}}}}}};
const F18=v2n=>{B2p:for(;;){if(JLTN(v2n,(20))){{let v2q=(JADD((96),v2n));return F1f(V7,v2q);}}else{(TR(F18(JQUO(v2n,(20)))));{let v2r=(JADD((96),(JREM(v2n,(20)))));return F1f(V7,v2r);}}}};
const F19=(v2s,v2t)=>{B2v:for(;;){if(JEQN((STR(v2s).length<<1),(STR(v2t).length<<1))){return F1b(v2s,v2t,(0));}else{return FALSE;}}};
const F1b=(v2w,v2z,v30)=>{B31:for(;;){{let v32=(JEQN(v30,(STR(v2w).length<<1))?TRUE:FALSE);if(v32!==FALSE){return v32;}else{if(((AR(STR(v2w),v30)<<1)|1)===((AR(STR(v2z),v30)<<1)|1)){{const v33=v2w,v34=v2z,v35=(JADD(v30,(2)));v2w=v33;v2z=v34;v30=v35;continue B31;}}else{return FALSE;}}}}};
const F1c=v36=>{B37:for(;;){return F1d(v36,(JSUB((STR(v36).length<<1),(2))),NIL);}};
const F1d=(v38,v39,v3b)=>{B3c:for(;;){if(JLTN(v39,(0))){return v3b;}else{{const v3d=v38,v3f=(JSUB(v39,(2))),v3g=({t:"pair",a:((AR(STR(v38),v39)<<1)|1),d:v3b});v38=v3d;v39=v3f;v3b=v3g;continue B3c;}}}};
const F1f=(v3h,v3j)=>{B3k:for(;;){{let v3m=(TR((v3n=>{return (v3n.f[1]);})(v3h)));if(v3m===C6){return ((IO.write_byte(IU(v3j))),VOID);}else{if(v3m===C7){{let v3p=v3h,v3q=({t:"pair",a:(I31(v3j)|1),d:(TR((v3r=>{return (v3r.f[2]);})(v3h)))});return ((v3p.f[2]=v3q),VOID);}}else{if(v3m===C8){return ((IO.fwrite(IU(TR((v3s=>{return (v3s.f[2]);})(v3h))),IU(v3j))),VOID);}else{return F1q(C9,Cb);}}}}}};
const F1g=(v3t,v3v)=>{B3w:for(;;){{let v3z=V7;return F23((()=>{return ((V7=v3t),VOID);}),v3v,(()=>{return ((V7=v3z),VOID);}));}}};
const F1h=(v40,...v41)=>{const v42=L2(v41);if(v42===NIL){return F1j(v40);}else{return F1g((PV(v42).a),(()=>{return F1j(v40);}));}};
const F1j=v43=>{B44:for(;;){if(v43 instanceof Uint8Array){(TR((v45=>{return F1f(V7,v45);})(68)));(F1m(v43,(0)));{let v46=(68);return F1f(V7,v46);}}else{if((KCHR(v43))!==FALSE){(TR((v47=>{return F1f(V7,v47);})(70)));(TR((v48=>{return F1f(V7,v48);})(184)));return F1n(v43);}else{if((v43.t)==="pair"){(TR((v49=>{return F1f(V7,v49);})(80)));(TR(F1h(PV(v43).a)));return F1k(PV(v43).d);}else{if((Array.isArray(v43)?TRUE:FALSE)!==FALSE){(TR((v4b=>{return F1f(V7,v4b);})(70)));(TR((v4c=>{return F1f(V7,v4c);})(80)));(TR((()=>{{let v4d=(0);B4f:for(;;){if(JLTN(v4d,(VEC(v43).length<<1))){((JZ(v4d))?VOID:(TR((v4g=>{return F1f(V7,v4g);})(64))));(TR(F1h(AR(VEC(v43),v4d))));{const v4h=(JADD(v4d,(2)));v4d=v4h;continue B4f;}}else{return VOID;}}}})()));{let v4j=(82);return F1f(V7,v4j);}}else{return F11(v43);}}}}}};
const F1k=v4k=>{B4m:for(;;){if(v4k===NIL){{let v4n=(82);return F1f(V7,v4n);}}else{if((v4k.t)==="pair"){(TR((v4p=>{return F1f(V7,v4p);})(64)));(TR(F1h(PV(v4k).a)));{const v4q=(PV(v4k).d);v4k=v4q;continue B4m;}}else{(TR((v4r=>{return F1f(V7,v4r);})(64)));(TR((v4s=>{return F1f(V7,v4s);})(92)));(TR((v4t=>{return F1f(V7,v4t);})(64)));(TR(F1h(v4k)));{let v4v=(82);return F1f(V7,v4v);}}}}};
const F1m=(v4w,v4z)=>{B50:for(;;){if(JLTN(v4z,(STR(v4w).length<<1))){(TR((v51=>{(((TR((v52=>{if(v52!==FALSE){return v52;}else{return (JEQN(v51,(184))?TRUE:FALSE);}})(JEQN(v51,(68))?TRUE:FALSE)))!==FALSE)?(TR((v53=>{return F1f(V7,v53);})(184))):VOID);{let v54=v51;return F1f(V7,v54);}})(I31((AR(STR(v4w),v4z)<<1)|1)&-2)));{const v55=v4w,v56=(JADD(v4z,(2)));v4w=v55;v4z=v56;continue B50;}}else{return VOID;}}};
const F1n=v57=>{B58:for(;;){{let v59=(I31(v57)&-2);if(JEQN(v59,(64))){return F14(Cc,(0));}else{if(JEQN(v59,(20))){return F14(Cd,(0));}else{if(JEQN(v59,(18))){return F14(Cf,(0));}else{{let v5b=v59;return F1f(V7,v5b);}}}}}}};
const F1p=(v5c,v5d,v5f)=>{B5g:for(;;){if(v5f===NIL){return v5d;}else{{const v5h=v5c,v5j=(TR(IC(v5c,[v5d,(PV(v5f).a)]))),v5k=(PV(v5f).d);v5c=v5h;v5d=v5j;v5f=v5k;continue B5g;}}}};
const F1q=(v5m,v5n,...v5p)=>{const v5q=L2(v5p);return F2m(TR(((v5r,v5s,v5t)=>{return (new Rec([Vc,v5r,v5s,v5t]));})(v5m,v5n,v5q)));};
const F1r=v5v=>{B5w:for(;;){{let v5z=(KFIX(v5v));if(v5z!==FALSE){return v5z;}else{{let v60=((v5v instanceof Fl)?TRUE:FALSE);if(v60!==FALSE){return v60;}else{{let v61=((typeof v5v==='bigint')?TRUE:FALSE);if(v61!==FALSE){return v61;}else{{let v62=((v5v instanceof Ratio)?TRUE:FALSE);if(v62!==FALSE){return v62;}else{return ((v5v instanceof Cx)?TRUE:FALSE);}}}}}}}}}};
const F1s=v63=>{B64:for(;;){{let v65=(KFIX(v63));if(v65!==FALSE){return v65;}else{{let v66=((typeof v63==='bigint')?TRUE:FALSE);if(v66!==FALSE){return v66;}else{if(((v63 instanceof Fl)?TRUE:FALSE)!==FALSE){return ((FLV(v63)===FLV(new Fl(Math.floor(FLV(v63)))))?TRUE:FALSE);}else{return FALSE;}}}}}}};
const F1t=v67=>{B68:for(;;){{let v69=(KFIX(v67));if(v69!==FALSE){return v69;}else{{let v6b=((typeof v67==='bigint')?TRUE:FALSE);if(v6b!==FALSE){return v6b;}else{{let v6c=((v67 instanceof Ratio)?TRUE:FALSE);if(v6c!==FALSE){return v6c;}else{if(((v67 instanceof Cx)?TRUE:FALSE)!==FALSE){if((F1t(v67.re))!==FALSE){{const v6d=(v67.im);v67=v6d;continue B68;}}else{return FALSE;}}else{return FALSE;}}}}}}}}};
const F1v=v6f=>{B6g:for(;;){if((v6f.t)==="pair"){{let v6h=(((PV(v6f).a)===NIL)?TRUE:FALSE);if(v6h!==FALSE){return v6h;}else{{const v6j=(PV(v6f).d);v6f=v6j;continue B6g;}}}}else{return FALSE;}}};
const F1w=v6k=>{B6m:for(;;){if(v6k===NIL){return NIL;}else{return ({t:"pair",a:(TR((v6n=>{return (PV(PV(v6n).a).a);})(v6k))),d:(F1w(PV(v6k).d))});}}};
const F1z=v6p=>{B6q:for(;;){if(v6p===NIL){return NIL;}else{return ({t:"pair",a:(TR((v6r=>{return (PV(PV(v6r).a).d);})(v6p))),d:(F1z(PV(v6p).d))});}}};
const F20=(v6s,v6t,...v6v)=>{const v6w=L2(v6v);if(v6w===NIL){return F21(v6s,v6t);}else{return F22(v6s,({t:"pair",a:v6t,d:v6w}));}};
const F21=(v6z,v70)=>{B71:for(;;){if(v70===NIL){return VOID;}else{(TR(IC(v6z,[(PV(v70).a)])));{const v72=v6z,v73=(PV(v70).d);v6z=v72;v70=v73;continue B71;}}}};
const F22=(v74,v75)=>{B76:for(;;){if((F1v(v75))!==FALSE){return VOID;}else{(TR(A2(v74,[],(F1w(v75)))));{const v77=v74,v78=(F1z(v75));v74=v77;v75=v78;continue B76;}}}};
const F23=(v79,v7b,v7c)=>{B7d:for(;;){(TR(IC(v79,[])));((V8=({t:"pair",a:({t:"pair",a:v79,d:v7c}),d:V8})),VOID);{let v7f=(TR(IC(v7b,[])));((V8=(PV(V8).d)),VOID);(TR(IC(v7c,[])));return v7f;}}};
const F24=(v7g,v7h,v7j)=>{B7k:for(;;){(F25(v7h));return (THR(v7g,v7j));}};
const F25=v7m=>{B7n:for(;;){if(V8===v7m){return VOID;}else{{let v7p=(PV(V8).a);((V8=(PV(V8).d)),VOID);(TR(IC((PV(v7p).d),[])));{const v7q=v7m;v7m=v7q;continue B7n;}}}}};
const F26=v7r=>{B7s:for(;;){if((KFIX(v7r))!==FALSE){return (BigInt(IU(v7r)));}else{return v7r;}}};
const F27=v7t=>{B7v:for(;;){if(((v7t instanceof Fl)?TRUE:FALSE)!==FALSE){return v7t;}else{if((KFIX(v7t))!==FALSE){return (new Fl(IU(v7t)));}else{if(((v7t instanceof Ratio)?TRUE:FALSE)!==FALSE){return (new Fl(FLV(F27(v7t.n))/FLV(F27(v7t.dd))));}else{{let v7w=v7t;return (new Fl(Number(v7w)));}}}}}};
const F28=(v7z,v80)=>{B81:for(;;){if((TR((v82=>{if(v82!==FALSE){return v82;}else{return ((v80 instanceof Cx)?TRUE:FALSE);}})((v7z instanceof Cx)?TRUE:FALSE)))!==FALSE){return F2v((F28((TR((v83=>{if(((v83 instanceof Cx)?TRUE:FALSE)!==FALSE){return (v83.re);}else{return v83;}})(v7z))),(TR((v84=>{if(((v84 instanceof Cx)?TRUE:FALSE)!==FALSE){return (v84.re);}else{return v84;}})(v80))))),(F28((TR((v85=>{if(((v85 instanceof Cx)?TRUE:FALSE)!==FALSE){return (v85.im);}else{return (0);}})(v7z))),(TR((v86=>{if(((v86 instanceof Cx)?TRUE:FALSE)!==FALSE){return (v86.im);}else{return (0);}})(v80))))));}else{if((TR((v87=>{if(v87!==FALSE){return v87;}else{return ((v80 instanceof Fl)?TRUE:FALSE);}})((v7z instanceof Fl)?TRUE:FALSE)))!==FALSE){return (new Fl(FLV(F27(v7z))+FLV(F27(v80))));}else{if((TR((v88=>{if(v88!==FALSE){return v88;}else{return ((v80 instanceof Ratio)?TRUE:FALSE);}})((v7z instanceof Ratio)?TRUE:FALSE)))!==FALSE){return F2t((F28((F2b((TR((v89=>{if(((v89 instanceof Ratio)?TRUE:FALSE)!==FALSE){return (v89.n);}else{return v89;}})(v7z))),(TR((v8b=>{if(((v8b instanceof Ratio)?TRUE:FALSE)!==FALSE){return (v8b.dd);}else{return (2);}})(v80))))),(F2b((TR((v8c=>{if(((v8c instanceof Ratio)?TRUE:FALSE)!==FALSE){return (v8c.n);}else{return v8c;}})(v80))),(TR((v8d=>{if(((v8d instanceof Ratio)?TRUE:FALSE)!==FALSE){return (v8d.dd);}else{return (2);}})(v7z))))))),(F2b((TR((v8f=>{if(((v8f instanceof Ratio)?TRUE:FALSE)!==FALSE){return (v8f.dd);}else{return (2);}})(v7z))),(TR((v8g=>{if(((v8g instanceof Ratio)?TRUE:FALSE)!==FALSE){return (v8g.dd);}else{return (2);}})(v80))))));}else{{let v8h=(TR((v8k=>{if((KFIX(v8k))!==FALSE){return (BigInt(IU(v8k)));}else{return v8k;}})(v7z))),v8j=(TR((v8m=>{if((KFIX(v8m))!==FALSE){return (BigInt(IU(v8m)));}else{return v8m;}})(v80)));return (BNRM(v8h+v8j));}}}}}};
const F29=(v8n,v8p)=>{B8q:for(;;){if((TR((v8r=>{if(v8r!==FALSE){return v8r;}else{return ((v8p instanceof Cx)?TRUE:FALSE);}})((v8n instanceof Cx)?TRUE:FALSE)))!==FALSE){return F2v((F29((TR((v8s=>{if(((v8s instanceof Cx)?TRUE:FALSE)!==FALSE){return (v8s.re);}else{return v8s;}})(v8n))),(TR((v8t=>{if(((v8t instanceof Cx)?TRUE:FALSE)!==FALSE){return (v8t.re);}else{return v8t;}})(v8p))))),(F29((TR((v8v=>{if(((v8v instanceof Cx)?TRUE:FALSE)!==FALSE){return (v8v.im);}else{return (0);}})(v8n))),(TR((v8w=>{if(((v8w instanceof Cx)?TRUE:FALSE)!==FALSE){return (v8w.im);}else{return (0);}})(v8p))))));}else{if((TR((v8z=>{if(v8z!==FALSE){return v8z;}else{return ((v8p instanceof Fl)?TRUE:FALSE);}})((v8n instanceof Fl)?TRUE:FALSE)))!==FALSE){return (new Fl(FLV(F27(v8n))-FLV(F27(v8p))));}else{if((TR((v90=>{if(v90!==FALSE){return v90;}else{return ((v8p instanceof Ratio)?TRUE:FALSE);}})((v8n instanceof Ratio)?TRUE:FALSE)))!==FALSE){return F2t((F29((F2b((TR((v91=>{if(((v91 instanceof Ratio)?TRUE:FALSE)!==FALSE){return (v91.n);}else{return v91;}})(v8n))),(TR((v92=>{if(((v92 instanceof Ratio)?TRUE:FALSE)!==FALSE){return (v92.dd);}else{return (2);}})(v8p))))),(F2b((TR((v93=>{if(((v93 instanceof Ratio)?TRUE:FALSE)!==FALSE){return (v93.n);}else{return v93;}})(v8p))),(TR((v94=>{if(((v94 instanceof Ratio)?TRUE:FALSE)!==FALSE){return (v94.dd);}else{return (2);}})(v8n))))))),(F2b((TR((v95=>{if(((v95 instanceof Ratio)?TRUE:FALSE)!==FALSE){return (v95.dd);}else{return (2);}})(v8n))),(TR((v96=>{if(((v96 instanceof Ratio)?TRUE:FALSE)!==FALSE){return (v96.dd);}else{return (2);}})(v8p))))));}else{{let v97=(TR((v99=>{if((KFIX(v99))!==FALSE){return (BigInt(IU(v99)));}else{return v99;}})(v8n))),v98=(TR((v9b=>{return (-v9b);})(TR((v9c=>{if((KFIX(v9c))!==FALSE){return (BigInt(IU(v9c)));}else{return v9c;}})(v8p)))));return (BNRM(v97+v98));}}}}}};
const F2b=(v9d,v9f)=>{B9g:for(;;){if((TR((v9h=>{if(v9h!==FALSE){return v9h;}else{return ((v9f instanceof Cx)?TRUE:FALSE);}})((v9d instanceof Cx)?TRUE:FALSE)))!==FALSE){{let v9j=(TR((v9p=>{if(((v9p instanceof Cx)?TRUE:FALSE)!==FALSE){return (v9p.re);}else{return v9p;}})(v9d))),v9k=(TR((v9q=>{if(((v9q instanceof Cx)?TRUE:FALSE)!==FALSE){return (v9q.im);}else{return (0);}})(v9d))),v9m=(TR((v9r=>{if(((v9r instanceof Cx)?TRUE:FALSE)!==FALSE){return (v9r.re);}else{return v9r;}})(v9f))),v9n=(TR((v9s=>{if(((v9s instanceof Cx)?TRUE:FALSE)!==FALSE){return (v9s.im);}else{return (0);}})(v9f)));return F2v((F29((F2b(v9j,v9m)),(F2b(v9k,v9n)))),(F28((F2b(v9j,v9n)),(F2b(v9k,v9m)))));}}else{if((TR((v9t=>{if(v9t!==FALSE){return v9t;}else{return ((v9f instanceof Fl)?TRUE:FALSE);}})((v9d instanceof Fl)?TRUE:FALSE)))!==FALSE){return (new Fl(FLV(F27(v9d))*FLV(F27(v9f))));}else{if((TR((v9v=>{if(v9v!==FALSE){return v9v;}else{return ((v9f instanceof Ratio)?TRUE:FALSE);}})((v9d instanceof Ratio)?TRUE:FALSE)))!==FALSE){return F2t((F2b((TR((v9w=>{if(((v9w instanceof Ratio)?TRUE:FALSE)!==FALSE){return (v9w.n);}else{return v9w;}})(v9d))),(TR((v9z=>{if(((v9z instanceof Ratio)?TRUE:FALSE)!==FALSE){return (v9z.n);}else{return v9z;}})(v9f))))),(F2b((TR((vb0=>{if(((vb0 instanceof Ratio)?TRUE:FALSE)!==FALSE){return (vb0.dd);}else{return (2);}})(v9d))),(TR((vb1=>{if(((vb1 instanceof Ratio)?TRUE:FALSE)!==FALSE){return (vb1.dd);}else{return (2);}})(v9f))))));}else{{let vb2=v9d,vb3=v9f;return (BNRM((F26(vb2))*(F26(vb3))));}}}}}};
const F2c=(vb4,vb5)=>{Bb6:for(;;){if((TR((vb7=>{if(vb7!==FALSE){return vb7;}else{return ((vb5 instanceof Fl)?TRUE:FALSE);}})((vb4 instanceof Fl)?TRUE:FALSE)))!==FALSE){return (new Fl(Math.trunc(FLV(new Fl(FLV(F27(vb4))/FLV(F27(vb5)))))));}else{if((((F1s(vb4))!==FALSE)?(F1s(vb5)):FALSE)!==FALSE){(((F2g(vb5,(0)))!==FALSE)?(TR(F1q(Cg,Ch))):VOID);{let vb8=vb4,vb9=vb5;return (BNRM((F26(vb8))/(F26(vb9))));}}else{return F1q(Cg,Cj);}}}};
const F2d=(vbb,vbc)=>{Bbd:for(;;){if((TR((vbf=>{if(vbf!==FALSE){return vbf;}else{return ((vbc instanceof Fl)?TRUE:FALSE);}})((vbb instanceof Fl)?TRUE:FALSE)))!==FALSE){{let vbg=(new Fl(Math.trunc(FLV(new Fl(FLV(F27(vbb))/FLV(F27(vbc)))))));return (new Fl(FLV(F27(vbb))-FLV(new Fl(FLV(vbg)*FLV(F27(vbc))))));}}else{if((((F1s(vbb))!==FALSE)?(F1s(vbc)):FALSE)!==FALSE){(((F2g(vbc,(0)))!==FALSE)?(TR(F1q(Ck,Ch))):VOID);{let vbh=vbb,vbj=vbc;return (BNRM((F26(vbh))%(F26(vbj))));}}else{return F1q(Ck,Cj);}}}};
const F2f=(vbk,vbm)=>{Bbn:for(;;){if((TR((vbp=>{if(vbp!==FALSE){return vbp;}else{return ((vbm instanceof Cx)?TRUE:FALSE);}})((vbk instanceof Cx)?TRUE:FALSE)))!==FALSE){return F1q(Cm,Cn);}else{if((TR((vbq=>{if(vbq!==FALSE){return vbq;}else{return ((vbm instanceof Fl)?TRUE:FALSE);}})((vbk instanceof Fl)?TRUE:FALSE)))!==FALSE){return ((FLV(F27(vbk))<FLV(F27(vbm)))?TRUE:FALSE);}else{if((TR((vbr=>{if(vbr!==FALSE){return vbr;}else{return ((vbm instanceof Ratio)?TRUE:FALSE);}})((vbk instanceof Ratio)?TRUE:FALSE)))!==FALSE){{const vbs=(F2b((TR((vbv=>{if(((vbv instanceof Ratio)?TRUE:FALSE)!==FALSE){return (vbv.n);}else{return vbv;}})(vbk))),(TR((vbw=>{if(((vbw instanceof Ratio)?TRUE:FALSE)!==FALSE){return (vbw.dd);}else{return (2);}})(vbm))))),vbt=(F2b((TR((vbz=>{if(((vbz instanceof Ratio)?TRUE:FALSE)!==FALSE){return (vbz.n);}else{return vbz;}})(vbm))),(TR((vc0=>{if(((vc0 instanceof Ratio)?TRUE:FALSE)!==FALSE){return (vc0.dd);}else{return (2);}})(vbk)))));vbk=vbs;vbm=vbt;continue Bbn;}}else{{let vc1=vbk,vc2=vbm;return (((F26(vc1))<(F26(vc2)))?TRUE:FALSE);}}}}}};
const F2g=(vc3,vc4)=>{Bc5:for(;;){if((TR((vc6=>{if(vc6!==FALSE){return vc6;}else{return ((vc4 instanceof Cx)?TRUE:FALSE);}})((vc3 instanceof Cx)?TRUE:FALSE)))!==FALSE){if((F2g((TR((vc7=>{if(((vc7 instanceof Cx)?TRUE:FALSE)!==FALSE){return (vc7.re);}else{return vc7;}})(vc3))),(TR((vc8=>{if(((vc8 instanceof Cx)?TRUE:FALSE)!==FALSE){return (vc8.re);}else{return vc8;}})(vc4)))))!==FALSE){{const vc9=(TR((vcc=>{if(((vcc instanceof Cx)?TRUE:FALSE)!==FALSE){return (vcc.im);}else{return (0);}})(vc3))),vcb=(TR((vcd=>{if(((vcd instanceof Cx)?TRUE:FALSE)!==FALSE){return (vcd.im);}else{return (0);}})(vc4)));vc3=vc9;vc4=vcb;continue Bc5;}}else{return FALSE;}}else{if((TR((vcf=>{if(vcf!==FALSE){return vcf;}else{return ((vc4 instanceof Fl)?TRUE:FALSE);}})((vc3 instanceof Fl)?TRUE:FALSE)))!==FALSE){return ((FLV(F27(vc3))===FLV(F27(vc4)))?TRUE:FALSE);}else{if((TR((vcg=>{if(vcg!==FALSE){return vcg;}else{return ((vc4 instanceof Ratio)?TRUE:FALSE);}})((vc3 instanceof Ratio)?TRUE:FALSE)))!==FALSE){if((F2g((TR((vch=>{if(((vch instanceof Ratio)?TRUE:FALSE)!==FALSE){return (vch.n);}else{return vch;}})(vc3))),(TR((vcj=>{if(((vcj instanceof Ratio)?TRUE:FALSE)!==FALSE){return (vcj.n);}else{return vcj;}})(vc4)))))!==FALSE){{const vck=(TR((vcn=>{if(((vcn instanceof Ratio)?TRUE:FALSE)!==FALSE){return (vcn.dd);}else{return (2);}})(vc3))),vcm=(TR((vcp=>{if(((vcp instanceof Ratio)?TRUE:FALSE)!==FALSE){return (vcp.dd);}else{return (2);}})(vc4)));vc3=vck;vc4=vcm;continue Bc5;}}else{return FALSE;}}else{{let vcq=vc3,vcr=vc4;return (((F26(vcq))===(F26(vcr)))?TRUE:FALSE);}}}}}};
const F2h=vcs=>{Bct:for(;;){return F27(vcs);}};
const F2j=(...vcv)=>{const vcw=L2(vcv);return F2k(vcw);};
const F2k=vcz=>{Bd0:for(;;){{let vd1=(F1p(((vd2,vd3)=>{return JADD(vd2,(STR(vd3).length<<1));}),(0),vcz));{let vd4=(new Uint8Array(IU(vd1)));{let vd5=vcz,vd6=(0);Bd7:for(;;){if(vd5===NIL){return vd4;}else{{let vd8=(PV(vd5).a);(TR((()=>{{let vd9=(0);Bdb:for(;;){if(JLTN(vd9,(STR(vd8).length<<1))){(AW(STR(vd4),(JADD(vd6,vd9)),IU((AR(STR(vd8),vd9)<<1)|1)));{const vdc=(JADD(vd9,(2)));vd9=vdc;continue Bdb;}}else{return VOID;}}}})()));{const vdd=(PV(vd5).d),vdf=(JADD(vd6,(STR(vd8).length<<1)));vd5=vdd;vd6=vdf;continue Bd7;}}}}}}}}};
const F2m=vdg=>{Bdh:for(;;){if(V9===NIL){return F2r(vdg);}else{{let vdj=(PV(V9).a);((V9=(PV(V9).d)),VOID);return TCI(vdj,[({t:"pair",a:Vb,d:vdg})]);}}}};
const F2n=vdk=>{Bdm:for(;;){return (()=>{const vdn={t:"pair",a:NIL,d:NIL},vdp=V8;try{return TR(IC((vds=>{((V9=({t:"pair",a:vds,d:V9})),VOID);{let vdt=(TR(IC(vdk,[])));((V9=(PV(V9).d)),VOID);return vdt;}}),[vdq=>TR(F24(vdn,vdp,vdq))]));}catch(vdr){if(vdr instanceof Esc&&vdr.p.a===vdn)return vdr.p.d;throw vdr;}})();}};
const F2p=vdv=>{Bdw:for(;;){if((vdv.t)==="pair"){return (((PV(vdv).a)===Vb)?TRUE:FALSE);}else{return FALSE;}}};
const F2q=(vdz,vf0,...vf1)=>{const vf2=L2(vf1);return F2m(TR(((vf3,vf4,vf5)=>{return (new Rec([Vc,vf3,vf4,vf5]));})(vdz,vf0,vf2)));};
const F2r=vf6=>{Bf7:for(;;){(TR(F11(Cp)));(((TR((vf8=>{return (KREC(vf8,Vc));})(vf6)))!==FALSE)?((TR(F11(TR((vf9=>{return (vf9.f[1]);})(vf6))))),(TR(F11(Cq))),(TR(F11(TR((vfb=>{return (vfb.f[2]);})(vf6))))),(F20((vfc=>{(TR(F11(Cr)));return F1h(vfc);}),(TR((vfd=>{return (vfd.f[3]);})(vf6)))))):(TR(F1h(vf6))));(TR(F10()));return (UNR());}};
const F2s=(vff,vfg)=>{Bfh:for(;;){{let vfj=(TR((vfn=>{if(JLTN(vfn,(0))){return JSUB((0),vfn);}else{return vfn;}})(vff))),vfk=(TR((vfp=>{if(JLTN(vfp,(0))){return JSUB((0),vfp);}else{return vfp;}})(vfg)));Bfm:for(;;){if((F2g(vfk,(0)))!==FALSE){return vfj;}else{{const vfq=vfk,vfr=(JREM(vfj,vfk));vfj=vfq;vfk=vfr;continue Bfm;}}}}}};
const F2t=(vfs,vft)=>{Bfv:for(;;){(((F2g(vft,(0)))!==FALSE)?(TR(F1q(Cs,Ch))):VOID);{let vfw=((JLTN(vft,(0)))?((JLTN(vfs,(0)))?FALSE:TRUE):(JLTN(vfs,(0))?TRUE:FALSE));{let vfz=(TR((vg0=>{if(JLTN(vg0,(0))){return JSUB((0),vg0);}else{return vg0;}})(vfs)));{let vg1=(TR((vg2=>{if(JLTN(vg2,(0))){return JSUB((0),vg2);}else{return vg2;}})(vft)));{let vg3=(F2s(vfz,vg1));{let vg4=(JQUO(vfz,vg3));{let vg5=(JQUO(vg1,vg3));{let vg6=((vfw!==FALSE)?(JSUB((0),vg4)):vg4);if((F2g(vg5,(2)))!==FALSE){return vg6;}else{return (new Ratio(vg6,vg5));}}}}}}}}}};
const F2v=(vg7,vg8)=>{Bg9:for(;;){if((((F1t(vg8))!==FALSE)?(F2g(vg8,(0))):FALSE)!==FALSE){return vg7;}else{if(((((vg7 instanceof Fl)?TRUE:FALSE)!==FALSE)?((((vg8 instanceof Fl)?TRUE:FALSE)!==FALSE)?FALSE:TRUE):FALSE)!==FALSE){return (new Cx(vg7,(F27(vg8))));}else{if(((((vg8 instanceof Fl)?TRUE:FALSE)!==FALSE)?((((vg7 instanceof Fl)?TRUE:FALSE)!==FALSE)?FALSE:TRUE):FALSE)!==FALSE){return (new Cx((F27(vg7)),vg8));}else{return (new Cx(vg7,vg8));}}}}};
const F2w=()=>{Bgb:for(;;){return (new JSRef(GPROX));}};
const F2z=vgc=>{Bgd:for(;;){{let vgf=(vgh=>{return ((NB.push(IU(I31(vgh)&-2))),VOID);}),vgg=vgc;return F20(vgf,(F1c(vgg)));}}};
const F30=vgj=>{Bgk:for(;;){(F2z(vgj));return (new JSRef(TDX()));}};
const F31=vgm=>{Bgn:for(;;){{let vgp=(W(JSL(vgm.v)));{let vgq=(new Uint8Array(IU(vgp)));{let vgr=(0);Bgs:for(;;){if(JEQN(vgr,vgp)){return vgq;}else{(AW(STR(vgq),vgr,IU(I31(W(STG[IU(vgr)]))|1)));{const vgt=(JADD(vgr,(2)));vgr=vgt;continue Bgs;}}}}}}}};
const F32=vgv=>{Bgw:for(;;){if((TR((vgz=>{return ((vgz instanceof JSRef)?TRUE:FALSE);})(vgv)))!==FALSE){return vgv;}else{if((F1r(vgv))!==FALSE){{let vh0=vgv;return (new JSRef((F2h(vh0)).v));}}else{if(vgv instanceof Uint8Array){return F30(vgv);}else{if(vgv instanceof Sym){return F30(SYMV(vgv).s);}else{if(vgv===TRUE){return Vd;}else{if(vgv===FALSE){return Vf;}else{if(typeof vgv==='function'){return (new JSRef(JFN(vgv)));}else{return F2q(Ct,Cv,vgv);}}}}}}}}};
const F33=vh1=>{Bh2:for(;;){{let vh3=(W(CBS[CBS.length-1].args.length));{let vh4=(JSUB(vh3,(2))),vh5=NIL;Bh6:for(;;){if(JLTN(vh4,(0))){return ((CBS[CBS.length-1].ret=(TR((vh7=>{if((F2p(vh7))!==FALSE){{let vh8=(PV(vh7).d);if(TRUE!==FALSE){return (new JSRef(void 0));}else{return F2m(vh8);}}}else{return vh7;}})(F2n(()=>{return F32(TR(A2(vh1,[],vh5)));})))).v),VOID);}else{{const vh9=(JSUB(vh4,(2))),vhb=({t:"pair",a:(new JSRef(CBS[CBS.length-1].args[IU(vh4)])),d:vh5});vh4=vh9;vh5=vhb;continue Bh6;}}}}}}};
const F34=(vhc,vhd)=>{Bhf:for(;;){(F2z(vhd));return (new JSRef(JGET(vhc.v)));}};
const F35=(vhg,vhh,vhj)=>{Bhk:for(;;){{let vhm=(TR(F32(vhj)));(F2z(vhh));return ((JSET(vhg.v,vhm.v)),VOID);}}};
const F36=(vhn,vhp,...vhq)=>{const vhr=L2(vhq);(F20((vhs=>{return ((AS.push((TR(F32(vhs))).v)),VOID);}),vhr));return (new JSRef(JCALL(vhn.v,vhp.v)));};
const F37=(vht,vhv,...vhw)=>{const vhz=L2(vhw);{let vj0=(F34(vht,vhv));(F20((vj1=>{return ((AS.push((TR(F32(vj1))).v)),VOID);}),vhz));return (new JSRef(JCALL(vj0.v,vht.v)));}};
const F38=()=>{Bj2:for(;;){{let vj3=(F34((new JSRef(GPROX)),Cw));if((TR((vj4=>{return F19(Cz,(F31(F34(vj4,C10))));})(vj3)))!==FALSE){return F37((F34((new JSRef(GPROX)),C11)),C12,(new JSRef(void 0)),C13,(F2j((F31(F34(vj3,C14))),(F31(F34(vj3,C15))))));}else{return VOID;}}}};
const C0=S("#vu8(");
const C1=S("#\x3c");
const C2=S("#\x3cprocedure>");
const C3=S("#\x3cunknown>");
const C4=S("+nan.0");
const C5=S("\x3cbig-flonum>");
const C6=new Sym(S("console-out"));
const C7=new Sym(S("string-out"));
const C8=new Sym(S("file-out"));
const C9=new Sym(S("write"));
const Cb=S("not an output port");
const Cc=S("space");
const Cd=S("newline");
const Cf=S("tab");
const Cg=new Sym(S("quotient"));
const Ch=S("division by zero");
const Cj=S("unsupported operand combination");
const Ck=new Sym(S("remainder"));
const Cm=new Sym(S("\x3c"));
const Cn=S("complex numbers are not ordered");
const Cp=S("unhandled exception: ");
const Cq=S(": ");
const Cr=S(" ");
const Cs=new Sym(S("/"));
const Ct=new Sym(S("->js"));
const Cv=S("cannot convert to a JS value");
const Cw=S("location");
const Cz=S("#_");
const C10=S("hash");
const C11=S("history");
const C12=S("replaceState");
const C13=S("");
const C14=S("pathname");
const C15=S("search");
const C16=new Sym(S("$port"));
const C17=new Sym(S("$error-object"));
const C18=S("true");
const C19=S("eval");
const C1b=S("false");
const C1c=S("document");
const C1d=S("keydown");
const C1f=S("Escape");
const C1g=S("key");
const C1h=S("#src-overlay");
const C1j=S("addEventListener");
const C1k=S("hashchange");
const JLTN=(a,b)=>(typeof a==='number'&&typeof b==='number')?a<b:((TR(F2f(a,b)))!==FALSE);const JZ=a=>typeof a==='number'?a===0:((F2g(a,(0)))!==FALSE);const JADD=(a,b)=>{if(typeof a==='number'&&typeof b==='number'){const s=a+b;if(((s<<1)>>1)===s)return s;}return F28(a,b);};const JSUB=(a,b)=>{if(typeof a==='number'&&typeof b==='number'){const s=a-b;if(((s<<1)>>1)===s)return s;}return F29(a,b);};const JEQN=(a,b)=>(typeof a==='number'&&typeof b==='number')?a===b:((F2g(a,b))!==FALSE);const JQUO=(a,b)=>{if(typeof a==='number'&&typeof b==='number'){const d=b>>1;if(d===0)throw new RangeError('divide by zero');return W(Math.trunc((a>>1)/d));}return TR(F2c(a,b));};const JREM=(a,b)=>{if(typeof a==='number'&&typeof b==='number'){if(b===0)throw new RangeError('divide by zero');return ((a%b)<<1)>>1;}return TR(F2d(a,b));};const BNRM=b=>(b>=-536870912n&&b<=536870911n)?(Number(b)<<1):b;const JFN=clo=>(...args)=>{const fr={args,ret:void 0};CBS.push(fr);try{F33(clo);}finally{CBS.pop();}return fr.ret;};const RSYMS=()=>({t:"pair",a:C6,d:{t:"pair",a:C7,d:{t:"pair",a:C8,d:{t:"pair",a:C9,d:{t:"pair",a:Cg,d:{t:"pair",a:Ck,d:{t:"pair",a:Cm,d:{t:"pair",a:Cs,d:{t:"pair",a:Ct,d:{t:"pair",a:C16,d:{t:"pair",a:C17,d:NIL}}}}}}}}}}});
export const rt={"false":FALSE,"true":TRUE,"null":NIL,"void":VOID,mem:(typeof MEMOBJ!=='undefined'?MEMOBJ:void 0)};
export const xports={[U("$jscb")]:F33};
export function main(io){if(io)IO=io;return TR((()=>{((V5=({t:"pair",a:C16,d:NIL})),VOID);((V6=(TR(((vj5,vj6,vj7)=>{return (new Rec([V5,vj5,vj6,vj7]));})(C6,(0),(0))))),VOID);((V7=V6),VOID);((V8=NIL),VOID);((V9=NIL),VOID);((Vb=({t:"pair",a:(0),d:(0)})),VOID);((Vc=({t:"pair",a:C17,d:NIL})),VOID);((Vd=(TR((vj8=>{return F36((F34((F2w()),C19)),(F2w()),vj8);})(C18)))),VOID);((Vf=(TR((vj9=>{return F36((F34((F2w()),C19)),(F2w()),vj9);})(C1b)))),VOID);(TR(((vjb,vjc,vjd)=>{return F37(vjb,C1j,vjc,vjd);})((F34((F2w()),C1c)),C1d,(vjf=>{(((TR(((vjg,vjh)=>{if(JEQN((STR(vjg).length<<1),(STR(vjh).length<<1))){return F1b(vjg,vjh,(0));}else{return FALSE;}})(C1f,(F31(F34(vjf,C1g))))))!==FALSE)?(TR((vjj=>{if((TR(((vjk,vjm)=>{if(JEQN((STR(vjk).length<<1),(STR(vjm).length<<1))){return F1b(vjk,vjm,(0));}else{return FALSE;}})(C1h,(F31(F34(vjj,C10))))))!==FALSE){return F35(vjj,C10,Cz);}else{return VOID;}})(F34((new JSRef(GPROX)),Cw)))):VOID);return (new JSRef(void 0));}))));(TR(((vjn,vjp,vjq)=>{return F37(vjn,C1j,vjp,vjq);})((F2w()),C1k,(vjr=>{(F38());return (new JSRef(void 0));}))));return F38();})());}
main();
