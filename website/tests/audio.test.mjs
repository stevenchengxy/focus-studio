import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {build} from 'esbuild';
const dir=await mkdtemp(join(tmpdir(),'focus-audio-'));
await build({entryPoints:['app/studio/audio-model.ts'],outfile:join(dir,'model.mjs'),bundle:true,platform:'node',format:'esm'});
const {envelopeGain,envelopePoints,voiceWindow,waveformPeaks}=await import(pathToFileURL(join(dir,'model.mjs')));
test.after(async()=>{await rm(dir,{recursive:true,force:true});});
const near=(a,b)=>assert.ok(Math.abs(a-b)<1e-7,`${a} != ${b}`);
test('gain respects trim boundaries, volume and fades',()=>{
 const e={volume:.8,fadeIn:1,fadeOut:2};
 near(envelopeGain(e,-.1,4),0);near(envelopeGain(e,.5,4),.4);
 near(envelopeGain(e,2,4),.8);near(envelopeGain(e,3,4),.4);
 near(envelopeGain(e,4.1,4),0);near(envelopeGain({...e,volume:9},1,4),2);
});
test('scheduled ramps match gain during overlapping fades and seek',()=>{
 const e={volume:.8,fadeIn:.8,fadeOut:.8};
 const points=envelopePoints(e,1,.2,.65);
 for(let i=0;i<=65;i++){
  const t=i/100;let left=points[0],right=points.at(-1);
  for(let j=1;j<points.length;j++)if(points[j].time>=t){left=points[j-1];right=points[j];break;}
  const value=right.time===left.time?left.value:left.value+(right.value-left.value)*(t-left.time)/(right.time-left.time);
  near(value,envelopeGain(e,.2+t,1));
 }
});
test('voice scheduling retains source trim, delay, seek and video end',()=>{
 const v={offset:3,inPoint:2,outPoint:7,volume:1,fadeIn:0,fadeOut:0};
 assert.deepEqual(voiceWindow(v,1,10),{delay:2,elapsed:0,offset:2,duration:5,length:5});
 assert.deepEqual(voiceWindow(v,4,6),{delay:0,elapsed:1,offset:3,duration:2,length:5});
 assert.equal(voiceWindow(v,9,10).duration,0);
});
test('waveform includes both stereo channels and clamps peaks',()=>{
 assert.deepEqual(waveformPeaks([new Float32Array([.25,0,0,0]),new Float32Array([0,.5,0,2])],2),[.5,1]);
 assert.deepEqual(waveformPeaks([],2),[0,0]);
});
