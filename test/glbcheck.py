#!/usr/bin/env python3
"""Structural GLB checker, stdlib only: container, chunk alignment, bufferView bounds,
accessor bounds/alignment, every index reference in range, embedded image magic, counts.
Usage: glbcheck.py file.glb  -> prints a JSON summary; exit 1 on any violation."""
import struct, json, sys
def check(path):
    # Two lists, not one.  A thing that could not be checked is not
    # an error -- reporting it as one fails a legal file, and a checker
    # that cries wolf is one people stop reading.  But it is not
    # silence either: it is named, in its own field, so that a caller
    # can refuse a file whose interesting parts all went unchecked.
    # Everything reported as an error below is something actually wrong.
    d=open(path,'rb').read(); errs=[]; skips=[]
    # The header is checked BEFORE anything is unpacked out of it.  A
    # file shorter than the 12-byte header used to reach struct.unpack
    # and raise, so the checker died instead of reporting -- and a
    # traceback from a checker is indistinguishable, to whoever reads
    # the log, from the checker not having been run.
    if len(d)<12: return {'errors':[f'shorter than a GLB header: {len(d)} bytes'],'not_checked':[]}
    if d[:4]!=b'glTF': return {'errors':['not a GLB'],'not_checked':[]}
    ver,total=struct.unpack('<II',d[4:12])
    # The version was read and never looked at.  A real p1.glb with the
    # version rewritten to 99 came back with an empty error list -- the
    # checker reported a clean bill of health on a container it does not
    # understand, which is worse than not checking, because a caller
    # reads the empty list as "this was verified".
    if ver!=2: errs.append(f'GLB container version {ver}, expected 2')
    if total!=len(d): errs.append(f'header length {total} != file {len(d)}')
    if len(d)<20: return {'errors':errs+['no room for a JSON chunk header'],'not_checked':skips}
    jl,jt=struct.unpack('<I4s',d[12:20])
    if jt!=b'JSON' or jl%4: errs.append('JSON chunk type/alignment')
    if 20+jl>len(d): return {'errors':errs+[f'JSON chunk of {jl} bytes runs past the file'],'not_checked':skips}
    try:
        j=json.loads(d[20:20+jl])
    except Exception as e:
        return {'errors':errs+[f'JSON chunk does not parse: {e}'],'not_checked':skips}
    off=20+jl; bin_=b''
    if off<len(d):
        bl,bt=struct.unpack('<I4s',d[off:off+8])
        if bt!=b'BIN\x00' or bl%4: errs.append('BIN chunk type/alignment')
        bin_=d[off+8:off+8+bl]
    bufs=j.get('buffers',[]); bvs=j.get('bufferViews',[]); accs=j.get('accessors',[])
    for i,b in enumerate(bufs):
        # A meshopt FALLBACK buffer has no uri and is not the BIN chunk:
        # its byteLength is the size the data decompresses to, and a
        # loader that does not implement the extension is meant to use
        # it as an all-zero placeholder.  Comparing it against the BIN
        # length reported a length mismatch on a perfectly good file --
        # a checker that cries wolf on a legal input is one people
        # stop reading, which costs more than the check was worth.
        if b.get('extensions',{}).get('EXT_meshopt_compression',{}).get('fallback'):
            continue
        if 'uri' not in b and b['byteLength']!=len(bin_): errs.append(f'buffer {i} byteLength {b["byteLength"]} != BIN {len(bin_)}')
    # A bufferView carrying EXT_meshopt_compression holds COMPRESSED
    # bytes: its byteLength is the compressed size, and an accessor's
    # count times its element size has nothing to do with it.  Reading
    # values out of one crashed this checker on examples/assets/
    # Box-mq.glb -- a file that has been in the tree throughout, so the
    # checker has been dying rather than checking on it, and a
    # traceback in a log is indistinguishable from not having run.
    # They are declined by name rather than skipped silently: an
    # unchecked thing that says nothing is an unchecked thing everyone
    # believes was checked.
    compressed=set()
    for i,bv in enumerate(bvs):
        if 'EXT_meshopt_compression' in bv.get('extensions',{}):
            compressed.add(i)
            skips.append(f'bufferView {i} is EXT_meshopt_compression, so its '
                         'bytes are compressed and accessor bounds over it are '
                         'not meaningful here')
        if not (isinstance(bv.get('buffer'),int) and not isinstance(bv.get('buffer'),bool) and 0<=bv['buffer']<len(bufs)): errs.append(f'bufferView {i} buffer ref out of range')
        o=bv.get('byteOffset',0)
        if o%4: errs.append(f'bufferView {i} offset {o} not 4-aligned')
        if i not in compressed and o+bv['byteLength']>len(bin_): errs.append(f'bufferView {i} out of BIN')
    CT={5120:1,5121:1,5122:2,5123:2,5125:4,5126:4}; NT={'SCALAR':1,'VEC2':2,'VEC3':3,'VEC4':4,'MAT4':16}
    for i,a in enumerate(accs):
        if 'bufferView' not in a: continue
        if not (isinstance(a['bufferView'],int) and not isinstance(a['bufferView'],bool) and 0<=a['bufferView']<len(bvs)): errs.append(f'accessor {i} bufferView ref out of range'); continue
        if a['bufferView'] in compressed: continue
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
        # None for an accessor whose bytes are compressed, or that has
        # no bufferView at all.  Every caller must check -- reading
        # through one of these is what crashed the checker, and the
        # crash was silent for as long as nobody read the log.
        a=accs[ai]
        if 'bufferView' not in a or a['bufferView'] in compressed: return None
        bv=bvs[a['bufferView']]; cs=CT[a['componentType']]; n=NT[a['type']]; el=cs*n
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
                    # Declined out loud.  `if idx` alone would also
                    # swallow an empty index list, so the three cases --
                    # checked, empty, not readable -- would have looked
                    # the same from outside.
                    if idx is None:
                        skips.append(f'mesh{mi}.prim{pi} indices are in a '
                                     'compressed bufferView, so index range is '
                                     'not verified here')
                    elif idx and max(idx)>=vcount:
                        errs.append(f'mesh{mi}.prim{pi} index {max(idx)} >= vertex count {vcount}')
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
    return {'errors':errs,'not_checked':skips,'counts':counts}
if __name__=='__main__':
    # An unexpected exception is REPORTED, not raised.  A traceback out
    # of a checker is indistinguishable, in a log, from the checker not
    # having been run -- and the caller that reads exit status sees a
    # failure either way while learning nothing about the file.  Any
    # crash in here is also a defect in this checker, so it says so and
    # names the place, rather than being turned into a bare error string
    # that reads like a verdict about the GLB.
    try:
        r=check(sys.argv[1])
    except Exception as e:
        import traceback
        where=traceback.extract_tb(sys.exc_info()[2])[-1]
        r={'errors':[f'glbcheck itself failed at {where.filename.split("/")[-1]}:'
                     f'{where.lineno} ({type(e).__name__}: {e}) -- this is a '
                     'defect in the checker, and says nothing about the file'],
           'checker_crashed':True}
    print(json.dumps(r,separators=(',',':'))); sys.exit(1 if r['errors'] else 0)
