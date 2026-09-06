#!/usr/bin/env python3
"""Structural GLB checker, stdlib only: container, chunk alignment, bufferView bounds,
accessor bounds/alignment, every index reference in range, embedded image magic, counts.
Usage: glbcheck.py file.glb  -> prints a JSON summary; exit 1 on any violation."""
import struct, json, sys
def check(path):
    d=open(path,'rb').read(); errs=[]
    if d[:4]!=b'glTF': return {'errors':['not a GLB']}
    ver,total=struct.unpack('<II',d[4:12])
    if total!=len(d): errs.append(f'header length {total} != file {len(d)}')
    jl,jt=struct.unpack('<I4s',d[12:20]); 
    if jt!=b'JSON' or jl%4: errs.append('JSON chunk type/alignment')
    j=json.loads(d[20:20+jl]); off=20+jl; bin_=b''
    if off<len(d):
        bl,bt=struct.unpack('<I4s',d[off:off+8])
        if bt!=b'BIN\x00' or bl%4: errs.append('BIN chunk type/alignment')
        bin_=d[off+8:off+8+bl]
    bufs=j.get('buffers',[]); bvs=j.get('bufferViews',[]); accs=j.get('accessors',[])
    for i,b in enumerate(bufs):
        if 'uri' not in b and b['byteLength']!=len(bin_): errs.append(f'buffer {i} byteLength {b["byteLength"]} != BIN {len(bin_)}')
    for i,bv in enumerate(bvs):
        if not (isinstance(bv.get('buffer'),int) and not isinstance(bv.get('buffer'),bool) and 0<=bv['buffer']<len(bufs)): errs.append(f'bufferView {i} buffer ref out of range')
        o=bv.get('byteOffset',0)
        if o%4: errs.append(f'bufferView {i} offset {o} not 4-aligned')
        if o+bv['byteLength']>len(bin_): errs.append(f'bufferView {i} out of BIN')
    CT={5120:1,5121:1,5122:2,5123:2,5125:4,5126:4}; NT={'SCALAR':1,'VEC2':2,'VEC3':3,'VEC4':4,'MAT4':16}
    for i,a in enumerate(accs):
        if 'bufferView' not in a: continue
        if not (isinstance(a['bufferView'],int) and not isinstance(a['bufferView'],bool) and 0<=a['bufferView']<len(bvs)): errs.append(f'accessor {i} bufferView ref out of range'); continue
        bv=bvs[a['bufferView']]; cs=CT[a['componentType']]; n=NT[a['type']]; el=cs*n
        stride=bv.get('byteStride',el); ao=a.get('byteOffset',0)
        if 'byteStride' in bv and (stride<el or stride%4): errs.append(f'accessor {i} byteStride {stride} < element {el} or not 4-aligned')
        if (bv.get('byteOffset',0)+ao)%cs: errs.append(f'accessor {i} misaligned')
        need=ao+(a['count']-1)*stride+el if a['count'] else ao
        if need>bv['byteLength']: errs.append(f'accessor {i} overruns bufferView {a["bufferView"]}')
    def ref(kind,idx,where):
        ok=isinstance(idx,int) and not isinstance(idx,bool) and 0<=idx<len(j.get(kind,[]))
        if not ok: errs.append(f'{where}: {kind}[{idx}] out of range')
        return ok
    for mi,m in enumerate(j.get('meshes',[])):
        for pi,p in enumerate(m['primitives']):
            for k,v in p['attributes'].items(): ref('accessors',v,f'mesh{mi}.prim{pi}.{k}')
            if 'indices' in p: ref('accessors',p['indices'],f'mesh{mi}.prim{pi}.indices')
            if 'material' in p: ref('materials',p['material'],f'mesh{mi}.prim{pi}.material')
            for ti,t in enumerate(p.get('targets',[])):
                for k,v in t.items(): ref('accessors',v,f'mesh{mi}.prim{pi}.target{ti}.{k}')
            if 'weights' in m and len(m['weights'])!=len(p.get('targets',[])): errs.append(f'mesh{mi} weights/targets count mismatch')
    for i,mat in enumerate(j.get('materials',[])):
        pbr=mat.get('pbrMetallicRoughness',{})
        for k in ('baseColorTexture','metallicRoughnessTexture'):
            if k in pbr: ref('textures',pbr[k]['index'],f'material{i}.{k}')
        for k in ('normalTexture','occlusionTexture','emissiveTexture'):
            if k in mat: ref('textures',mat[k]['index'],f'material{i}.{k}')
    for i,t in enumerate(j.get('textures',[])):
        if 'source' in t: ref('images',t['source'],f'texture{i}.source')
        if 'sampler' in t: ref('samplers',t['sampler'],f'texture{i}.sampler')
    MAGIC={'image/png':b'\x89PNG','image/jpeg':b'\xff\xd8'}
    for i,im in enumerate(j.get('images',[])):
        if 'bufferView' in im:
            if not ref('bufferViews',im['bufferView'],f'image{i}'): continue
            bv=bvs[im['bufferView']]
            head=bin_[bv.get('byteOffset',0):bv.get('byteOffset',0)+4]
            mg=MAGIC.get(im.get('mimeType'))
            if mg and not head.startswith(mg): errs.append(f'image{i} bytes are not {im["mimeType"]}')
    for i,s in enumerate(j.get('skins',[])):
        for n in s['joints']: ref('nodes',n,f'skin{i}.joints')
        if 'inverseBindMatrices' in s:
            if not ref('accessors',s['inverseBindMatrices'],f'skin{i}.ibm'): continue
            a=accs[s['inverseBindMatrices']]
            if a['count']!=len(s['joints']) or a['type']!='MAT4': errs.append(f'skin{i} ibm count/type')
    for i,n in enumerate(j.get('nodes',[])):
        for c in n.get('children',[]): ref('nodes',c,f'node{i}.children')
        for k,kind in (('mesh','meshes'),('skin','skins'),('camera','cameras')):
            if k in n: ref(kind,n[k],f'node{i}.{k}')
    for i,a in enumerate(j.get('animations',[])):
        for c in a['channels']:
            ref('nodes',c['target']['node'],f'anim{i}.channel.node')
            if not (0<=c['sampler']<len(a['samplers'])): errs.append(f'anim{i} channel sampler out of range')
        for s in a['samplers']:
            ref('accessors',s['input'],f'anim{i}.sampler.input'); ref('accessors',s['output'],f'anim{i}.sampler.output')
    # ---- second layer: what the spec requires beyond reachability ----
    CT2={5120:'b',5121:'B',5122:'h',5123:'H',5125:'I',5126:'f'}
    def values(ai):
        a=accs[ai]; bv=bvs[a['bufferView']]; cs=CT[a['componentType']]; n=NT[a['type']]; el=cs*n
        stride=bv.get('byteStride',el); off=bv.get('byteOffset',0)+a.get('byteOffset',0); fmt='<'+CT2[a['componentType']]
        return [struct.unpack_from(fmt,bin_,off+i*stride+k*cs)[0] for i in range(a['count']) for k in range(n)]
    users={}
    for i,a in enumerate(accs):
        if 'bufferView' in a: users.setdefault(a['bufferView'],[]).append(i)
    for mi,m in enumerate(j.get('meshes',[])):
        for pi,p in enumerate(m['primitives']):
            attrs=p['attributes']
            if 'POSITION' in attrs:
                pa=accs[attrs['POSITION']]; vcount=pa['count']
                if 'min' not in pa or 'max' not in pa: errs.append(f'mesh{mi}.prim{pi}.POSITION accessor lacks min/max')
                for k,v in attrs.items():
                    if accs[v]['count']!=vcount: errs.append(f'mesh{mi}.prim{pi}.{k} count != POSITION count')
                if 'indices' in p:
                    idx=values(p['indices'])
                    if idx and max(idx)>=vcount: errs.append(f'mesh{mi}.prim{pi} index {max(idx)} >= vertex count {vcount}')
                for ti,t in enumerate(p.get('targets',[])):
                    for k,v in t.items():
                        if accs[v]['count']!=vcount: errs.append(f'mesh{mi}.prim{pi}.target{ti}.{k} count != vertex count')
                        if k not in attrs: errs.append(f'mesh{mi}.prim{pi}.target{ti}.{k}: no base {k} attribute to displace')
                    if 'POSITION' in t and ('min' not in accs[t['POSITION']] or 'max' not in accs[t['POSITION']]):
                        errs.append(f'mesh{mi}.prim{pi}.target{ti}.POSITION accessor lacks min/max')
            for k,v in attrs.items():
                bv=bvs[accs[v]['bufferView']]
                if len(users.get(accs[v]['bufferView'],[]))>1 and 'byteStride' not in bv:
                    errs.append(f'mesh{mi}.prim{pi}.{k}: shared vertex bufferView {accs[v]["bufferView"]} has no byteStride')
    for si,sc in enumerate(j.get('scenes',[])):
        for r in sc.get('nodes',[]): ref('nodes',r,f'scene{si}.nodes')
    for i,a in enumerate(j.get('animations',[])):
        # a sampler's output count is exactly input x (3 if cubic) x (the
        # node's morph target count for a weights channel, else 1)
        paths={}
        for ch in a['channels']:
            paths.setdefault(ch['sampler'],set()).add((ch['target']['path'],ch['target']['node']))
        for si,sm in enumerate(a['samplers']):
            if sm['input'] in range(len(accs)) and sm['output'] in range(len(accs)):
                k=3 if sm.get('interpolation')=='CUBICSPLINE' else 1
                for path,node in paths.get(si,{('?',None)}):
                    m=1
                    if path=='weights':
                        nd=j['nodes'][node] if isinstance(node,int) and 0<=node<len(j.get('nodes',[])) else {}
                        mesh=j['meshes'][nd['mesh']] if 'mesh' in nd else None
                        m=len(mesh['primitives'][0].get('targets',[])) if mesh else 0
                    want=accs[sm['input']]['count']*k*m
                    if accs[sm['output']]['count']!=want: errs.append(f'anim{i}.sampler{si} ({path}): output count {accs[sm["output"]]["count"]} != {want}')
    for i,a in enumerate(accs):
        if 'sparse' in a: errs.append(f'accessor {i}: sparse accessors are not checked here')
    counts={k:len(j.get(k,[])) for k in ('meshes','materials','textures','images','samplers','skins','cameras','animations','nodes','accessors','bufferViews')}
    counts['targets_per_primitive']=[len(p.get('targets',[])) for m in j.get('meshes',[]) for p in m['primitives']]
    return {'errors':errs,'counts':counts}
if __name__=='__main__':
    r=check(sys.argv[1]); print(json.dumps(r,separators=(',',':'))); sys.exit(1 if r['errors'] else 0)
