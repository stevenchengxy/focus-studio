'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {CaptureController} = require('../src/capture.cjs');
const {SITE_ORIGIN, STUDIO_URL} = require('../src/policy.cjs');
function fixture(choose = async () => ({id: 'screen:1', audio: true})) {
  const frame = {url: STUDIO_URL}; const wc = {mainFrame: frame, isDestroyed: () => false};
  const request = {frame, securityOrigin: SITE_ORIGIN, userGesture: true, videoRequested: true, audioRequested: true};
  const controller = new CaptureController({getContents: () => wc, getSources: async () => [{id: 'screen:1', name: 'Screen'}], choose, platform: 'win32'});
  return {frame, wc, request, controller};
}
test('capture never auto-selects a screen; cancellation grants nothing', async () => {
  let called = false;
  const f = fixture(async () => { called = true; return null; }); const result = [];
  await f.controller.handle(f.request, value => result.push(value));
  assert.equal(called, true); assert.deepEqual(result, [null]);
});
test('captures are rejected without user activation or from child/untrusted frames', async () => {
  for (const patch of [{userGesture: false}, {videoRequested: false}, {securityOrigin: 'https://evil.test'}, {frame: {url: STUDIO_URL}}]) {
    const f = fixture(() => assert.fail('Must not enumerate/choose')); const result = [];
    await f.controller.handle({...f.request, ...patch}, value => result.push(value)); assert.deepEqual(result, [null]);
  }
});
test('navigation while choosing cancels capture; simultaneous request is denied', async () => {
  let answer; const f = fixture(() => new Promise(resolve => { answer = resolve; })); const first = []; const second = [];
  const pending = f.controller.handle(f.request, value => first.push(value)); await new Promise(resolve => setImmediate(resolve));
  await f.controller.handle(f.request, value => second.push(value)); assert.deepEqual(second, [null]);
  f.frame.url = 'https://evil.test'; answer({id: 'screen:1', audio: true}); await pending;
  assert.deepEqual(first, [null]); assert.equal(f.controller.busy, false);
});
test('portal denial and destroyed-frame callback do not leave capture locked', async () => {
  const f = fixture(); f.controller.getSources = async () => { throw new Error('PipeWire cancelled'); };
  const result = []; await f.controller.handle(f.request, value => result.push(value)); assert.deepEqual(result, [null]);
  assert.equal(f.controller.busy, false);
  f.controller.getSources = async () => [{id: 'screen:1'}];
  await f.controller.handle(f.request, () => { throw new Error('Frame destroyed'); });
  assert.equal(f.controller.busy, false);
});
