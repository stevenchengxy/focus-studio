import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import ts from 'typescript';
const transpile=source=>ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022}}).outputText;
const moduleURL=source=>`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`;
const releaseSource=await readFile(new URL('../lib/releases.ts',import.meta.url),'utf8');
const installerSource=await readFile(new URL('../lib/installers.ts',import.meta.url),'utf8');
const routeSource=await readFile(new URL('../app/api/download/[platform]/route.ts',import.meta.url),'utf8');
const fixture=JSON.parse(await readFile(new URL('./fixtures/github-releases.json',import.meta.url),'utf8'));
let id=0;
async function freshReleases(){return import(moduleURL(transpile(releaseSource)+`\n// independent fixture ${++id}`));}
async function freshRoute(){
  const releases=moduleURL(transpile(releaseSource)+`\n// independent route ${++id}`);
  const installers=moduleURL(transpile(installerSource));
  const runtime=moduleURL('export const settings=()=>({});');
  return import(moduleURL(transpile(routeSource).replace("'@/lib/releases'",JSON.stringify(releases))
    .replace("'@/lib/installers'",JSON.stringify(installers)).replace("'@/lib/server/runtime'",JSON.stringify(runtime))));
}
test('only completed release JSON is reused across Worker requests',async()=>{
  const {releaseCatalog}=await freshReleases(); let calls=0; let finish;
  const wait=new Promise(resolve=>{finish=resolve});
  const fetcher=async()=>{calls++; await wait; return Response.json(fixture)};
  const one=releaseCatalog(fetcher),two=releaseCatalog(fetcher);
  assert.equal(calls,2,'pending IO must not be shared between request contexts');
  finish(); await Promise.all([one,two]);
  await releaseCatalog(async()=>{throw Error('should use parsed JSON cache')});
});
test('catalog diagnostic reveals bounded upstream status without logging request data',async t=>{
  const {releaseCatalog}=await freshReleases();const logs=[];
  t.mock.method(console,'error',(...args)=>logs.push(args));
  await assert.rejects(releaseCatalog(async()=>new Response('API rate limit exceeded',{status:403,headers:{'x-ratelimit-remaining':'0'}})));
  assert.equal(logs[0][1].status,403);assert.equal(logs[0][1].remaining,'0');
  assert.ok(!JSON.stringify(logs).includes('Authorization'));
});
test('generic download redirects to exact identity and rejects unsafe resumes',async t=>{
  const {GET}=await freshRoute();let installerFetches=0;
  t.mock.method(globalThis,'fetch',async url=>{
    if(String(url).startsWith('https://raw.githubusercontent.com/'))return Response.json(fixture);
    installerFetches++; return new Response(new Uint8Array([1]),{headers:{'Content-Type':'application/octet-stream'}});
  });
  const params={params:Promise.resolve({platform:'mac'})};
  const response=await GET(new Request('https://studio.test/api/download/mac'),params);
  assert.equal(response.status,307);const pinned=new URL(response.headers.get('location'));
  assert.equal(pinned.origin,'https://studio.test');assert.equal(pinned.searchParams.get('release'),'v1.14.2-preview.1');
  assert.equal(pinned.searchParams.get('asset'),'Focus-Studio-1.14.2-universal-local.dmg');
  assert.equal(installerFetches,0);
  const unsafe=await GET(new Request('https://studio.test/api/download/mac',{headers:{Range:'bytes=100-'}}),params);
  assert.equal(unsafe.status,409);assert.equal(installerFetches,0);
  const complete=await GET(new Request(pinned),params);
  assert.equal(complete.status,200);assert.equal(installerFetches,1);
});

test('versioned update URLs permit fresh byte probes on every platform while unsafe unpinned ranges stay blocked',async t=>{
  const {GET}=await freshRoute();const upstream=[];
  t.mock.method(globalThis,'fetch',async(url,options)=>{
    if(String(url).startsWith('https://raw.githubusercontent.com/'))return Response.json(fixture);
    upstream.push({url:String(url),range:options.headers.get('range')});
    return new Response(new Uint8Array(16),{status:206,headers:{'Content-Type':'application/octet-stream','Content-Range':'bytes 0-15/128','Content-Length':'16'}});
  });
  for(const [platform,version] of [['mac','1.14.2'],['windows','0.1.0'],['linux','0.1.0']]) {
    const params={params:Promise.resolve({platform})};
    const original=`https://studio.test/api/download/${platform}?channel=preview&version=${version}`;
    for(const range of ['bytes=0-15','bytes=0-']) {
      const before=upstream.length;
      const response=await GET(new Request(original,{headers:{Range:range}}),params);
      assert.equal(response.status,307,`${platform}: ${range}`);
      assert.equal(response.headers.get('Cache-Control'),'no-store');
      assert.equal(upstream.length,before,'resolve identity before fetching installer bytes');
      const pinned=new URL(response.headers.get('Location'));
      assert.equal(pinned.searchParams.get('version'),version);
      assert.ok(pinned.searchParams.get('release'));assert.ok(pinned.searchParams.get('asset'));
      const download=await GET(new Request(pinned,{headers:{Range:range}}),params);
      assert.equal(download.status,206);assert.equal(download.headers.get('Content-Range'),'bytes 0-15/128');
      assert.equal((await download.arrayBuffer()).byteLength,16);
      assert.equal(upstream.at(-1).range,range,'redirect keeps initial Range intact');
    }
    for(const range of ['bytes=16-','bytes=-16','bytes=0-15,32-47','bytes=bad','']) {
      const before=upstream.length;
      const response=await GET(new Request(original,{headers:{Range:range}}),params);
      assert.equal(response.status,409,`${platform}: ${range}`);
      assert.ok(new URL(response.headers.get('Location')).searchParams.get('asset'));
      assert.equal(upstream.length,before);
    }
  }
});

test('pinned nonzero resume and suffix ranges still reach the original installer unchanged',async t=>{
  const {GET}=await freshRoute();const seen=[];
  t.mock.method(globalThis,'fetch',async(url,options)=>{
    if(String(url).startsWith('https://raw.githubusercontent.com/'))return Response.json(fixture);
    seen.push({url:String(url),range:options.headers.get('range'),ifRange:options.headers.get('if-range')});
    return new Response(new Uint8Array(16),{status:206,headers:{'Content-Type':'application/octet-stream','Content-Range':'bytes 112-127/128'}});
  });
  const params={params:Promise.resolve({platform:'mac'})};
  const initial=await GET(new Request('https://studio.test/api/download/mac'),params);
  for(const range of ['bytes=112-','bytes=-16']) {
    const response=await GET(new Request(initial.headers.get('Location'),{headers:{Range:range,'If-Range':'"original-etag"'}}),params);
    assert.equal(response.status,206);assert.equal(seen.at(-1).range,range);assert.equal(seen.at(-1).ifRange,'"original-etag"');
    assert.match(seen.at(-1).url,/\/v1\.14\.2-preview\.1\/Focus-Studio-1\.14\.2-universal-local\.dmg$/);
  }
});

test('public release feed avoids the shared anonymous GitHub API quota',async()=>{
  const {releaseCatalog,selectRelease}=await freshReleases();const calls=[];
  const catalog=await releaseCatalog(async(url,options)=>{
    calls.push(String(url));
    assert.equal(options.cf.cacheTtl,300);
    assert.equal(options.cf.cacheTtlByStatus['400-599'],0);
    return Response.json(fixture);
  });
  assert.deepEqual(calls,['https://raw.githubusercontent.com/stevenchengxy/focus-studio/release-feed/releases.json']);
  assert.equal(selectRelease(catalog,'mac','preview').info.version,'1.14.2');
  assert.equal(selectRelease(catalog,'windows','preview').info.version,'0.1.0');
});
test('only an unpublished feed can bootstrap from GitHub API',async t=>{
  t.mock.method(console,'warn',()=>{});t.mock.method(console,'error',()=>{});
  const {releaseCatalog}=await freshReleases();const calls=[];
  const catalog=await releaseCatalog(async url=>{
    calls.push(String(url));
    return calls.length===1?new Response(null,{status:404}):Response.json(fixture);
  });
  assert.equal(calls.length,2);assert.ok(calls[1].startsWith('https://api.github.com/'));
  assert.deepEqual(catalog,fixture);
  for(const response of [new Response('bad gateway',{status:503}),Response.json({draft:false}),new Response('not json')]){
    const fresh=await freshReleases();let requests=0;
    await assert.rejects(fresh.releaseCatalog(async()=>{requests++;return response;}));
    assert.equal(requests,1,'an established feed failure must not silently change source');
  }
});
test('oversized feed is cancelled before buffering its full body',async t=>{
  t.mock.method(console,'error',()=>{});
  const {releaseCatalog}=await freshReleases();let cancelled=false;
  const stream=new ReadableStream({start(controller){controller.enqueue(new Uint8Array(4_000_001));},cancel(){cancelled=true;}});
  await assert.rejects(releaseCatalog(async()=>new Response(stream)),/too large/);
  assert.equal(cancelled,true);
});
