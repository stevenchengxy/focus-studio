import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import ts from 'typescript';
const source = await readFile(new URL('../lib/releases.ts', import.meta.url), 'utf8');
const js = ts.transpileModule(source, {compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022}}).outputText;
const {selectRelease,releaseOptions,compareVersions} = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);
const repo='https://github.com/stevenchengxy/focus-studio';
function release(version,preview=true,names=[`Focus-Studio-${version}-universal-local.dmg`]) {
  return {draft:false,prerelease:preview,name:`Focus Studio ${version}`,published_at:'2026-10-14T00:00:00Z',html_url:`${repo}/releases/tag/v${version}`,assets:names.map(name=>({name,state:'uploaded',size:100,browser_download_url:`${repo}/releases/download/v${version}/${name}`}))};
}
test('release selection uses semantic version, channels and uploaded installer assets',()=>{
  const data=[release('1.9.0',false),release('1.10.0'),{...release('2.0.0'),draft:true},release('3.0.0',false,['Source.zip'])];
  assert.ok(compareVersions('1.10.0','1.9.0')>0);
  assert.equal(selectRelease(data,'mac','preview').info.version,'1.10.0');
  assert.equal(selectRelease(data,'mac','stable').info.version,'1.9.0');
  assert.equal(selectRelease(data,'mac','preview','1.9.0').info.version,'1.9.0');
  assert.equal(selectRelease(data,'mac','stable','1.10.0'),null);
  assert.match(selectRelease(data,'mac','preview').info.download_url,/channel=preview&version=1.10.0$/);
});
test('desktop version comes from its installer, not the native Mac release tag',()=>{
  const data=[release('1.14.3',true,['Focus-Studio-Desktop-0.1.1-windows-x64.exe','Focus-Studio-Desktop-0.1.1-linux-x86_64.AppImage'])];
  for(const platform of ['windows','linux'])assert.equal(selectRelease(data,platform,'preview').info.version,'0.1.1');
  assert.equal(selectRelease(data,'mac','preview'),null);
});
test('foreign URLs, unfinished assets and invalid channel inputs are rejected',()=>{
  const data=release('1.14.3');data.assets[0].browser_download_url='https://evil.test/Focus-Studio-1.14.3-universal-local.dmg';
  assert.equal(selectRelease([data],'mac','preview'),null);
  const pending=release('1.14.3');pending.assets[0].state='new';
  assert.equal(selectRelease([pending],'mac','preview'),null);
  assert.equal(releaseOptions(new URL('https://studio.test/api/releases?platform=__proto__')),null);
  assert.equal(releaseOptions(new URL('https://studio.test/api/releases?channel=nightly')),null);
  assert.equal(releaseOptions(new URL('https://studio.test/api/releases?version=latest')),null);
});
test('published GitHub catalog shape selects real native and desktop installers', async()=>{
  const data=JSON.parse(await readFile(new URL('./fixtures/github-releases.json',import.meta.url),'utf8'));
  assert.equal(selectRelease(data,'mac','preview').info.version,'1.14.2');
  for(const platform of ['windows','linux']) assert.equal(selectRelease(data,platform,'preview').info.version,'0.1.0');
  assert.equal(selectRelease(data,'mac','stable'),null);
});
test('exact tag and filename keep a download pinned across preview builds',()=>{
  const first=release('1.14.3'), second=release('1.14.3');
  first.html_url += '-preview.1'; second.html_url += '-preview.2';
  first.assets[0].browser_download_url=first.assets[0].browser_download_url.replace('/v1.14.3/','/v1.14.3-preview.1/');
  second.assets[0].browser_download_url=second.assets[0].browser_download_url.replace('/v1.14.3/','/v1.14.3-preview.2/');
  second.published_at='2026-10-15T00:00:00Z';
  const name=first.assets[0].name;
  const old=selectRelease([second,first],'mac','preview','1.14.3','v1.14.3-preview.1',name);
  assert.match(old.assetURL,/preview\.1/);
  assert.match(old.pinnedURL,/release=v1.14.3-preview.1&asset=/);
  // Metadata contract remains compatible with already packaged update clients.
  assert.deepEqual([...new URL(old.info.download_url).searchParams.keys()],['channel','version']);
  assert.equal(releaseOptions(new URL('https://studio.test/?release=v1.14.3-preview.1')),null);
});
test('malformed catalog entries are ignored rather than breaking valid releases',()=>{
  assert.equal(selectRelease([null,{}, {...release('8.0.0'),html_url:3},release('1.14.3')],'mac','preview').info.version,'1.14.3');
});
