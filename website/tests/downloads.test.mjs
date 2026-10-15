import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';
const source = await readFile(new URL('../lib/installers.ts', import.meta.url), 'utf8');
const js = ts.transpileModule(source, {compilerOptions: {target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022}}).outputText;
const {installerFor, installerResponse} = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);

test('missing, source archive or mismatched configuration keeps a verified installer', () => {
  for (const bad of [undefined, 'https://github.com/stevenchengxy/focus-studio/releases', 'https://github.com/stevenchengxy/focus-studio/archive/main.zip', 'https://github.com/stevenchengxy/focus-studio/releases/download/v1/app.exe', 'http://127.0.0.1/x.dmg']) {
    assert.ok(installerFor('mac', bad).url.endsWith('.dmg'));
  }
  assert.equal(installerFor('__proto__'), null);
});
test('streamed installer has correct filename and preserves resume response', async () => {
  const body = new Uint8Array([77, 90, 1, 2]);
  const result = await installerResponse(new Request('https://studio.test/api/download/windows', {headers:{Range:'bytes=0-3'}}), 'windows', undefined, async (url, options) => {
    assert.equal(options.headers.get('range'), 'bytes=0-3');
    return new Response(body, {status:206, headers:{'Content-Type':'application/octet-stream','Content-Length':'4','Content-Range':'bytes 0-3/100'}});
  });
  assert.equal(result.status,206);
  assert.match(result.headers.get('content-disposition'), /attachment; filename=".*\.exe"/);
  assert.equal(result.headers.get('content-range'), 'bytes 0-3/100');
  assert.deepEqual(new Uint8Array(await result.arrayBuffer()), body);
});
test('HTML errors never masquerade as installer downloads', async () => {
  for (const status of [200,404,503]) {
    const response = await installerResponse(new Request('https://studio.test/api/download/mac'), 'mac', undefined, async () => new Response('<html>Error</html>', {status,headers:{'content-type':'text/html'}}));
    assert.equal(response.status,503);
    assert.equal(response.headers.get('content-disposition'),null);
  }
});
test('unsatisfiable resume range keeps upstream416 and total size',async()=>{
  const result=await installerResponse(new Request('https://studio.test/api/download/mac',{headers:{Range:'bytes=100-'}}),'mac',undefined,async()=>new Response(null,{status:416,headers:{'Content-Range':'bytes */100','ETag':'"release-a"'}}));
  assert.equal(result.status,416);
  assert.equal(result.headers.get('content-range'),'bytes */100');
  assert.equal(result.headers.get('etag'),'"release-a"');
  assert.equal(result.headers.get('content-disposition'),null);
});
test('invalid range syntax is not forwarded to installer storage',async()=>{
  const result=await installerResponse(new Request('https://studio.test/api/download/mac',{headers:{Range:'bytes=-','If-Range':'"wrong"'}}),'mac',undefined,async(url,options)=>{
    assert.equal(options.headers.get('range'),null); assert.equal(options.headers.get('if-range'),null);
    return new Response(new Uint8Array([1]),{headers:{'Content-Type':'application/octet-stream'}});
  });
  assert.equal(result.status,200);
});
