export interface AudioEnvelope { volume: number; fadeIn: number; fadeOut: number; }
export interface VoiceEdit extends AudioEnvelope { assetId?: string; offset: number; inPoint: number; outPoint: number; }
export interface SoundEdit { source: AudioEnvelope; voice: VoiceEdit | null; }
export const defaultSound = (): SoundEdit => ({source:{volume:1,fadeIn:0,fadeOut:0},voice:null});
const finite = (value:number, fallback=0) => Number.isFinite(value) ? value : fallback;
export const bounded = (value:number, min:number, max:number) => Math.max(min,Math.min(max,finite(value,min)));

/** Preview and export use the same linear envelope, including overlapping fades. */
export function envelopeGain(envelope:AudioEnvelope, time:number, length:number) {
  if(time<0||time>length||length<=0)return 0;
  const fadeIn=bounded(envelope.fadeIn,0,length),fadeOut=bounded(envelope.fadeOut,0,length);
  return bounded(envelope.volume,0,2)*Math.min(1,fadeIn?time/fadeIn:1,fadeOut?(length-time)/fadeOut:1);
}

export function voiceWindow(voice:VoiceEdit, videoTime:number, videoEnd:number) {
  const length=Math.max(0,voice.outPoint-voice.inPoint);
  const elapsed=Math.max(0,videoTime-voice.offset);
  const delay=Math.max(0,voice.offset-videoTime);
  const remaining=Math.min(length-elapsed,videoEnd-Math.max(videoTime,voice.offset));
  return {delay,elapsed,offset:voice.inPoint+elapsed,duration:Math.max(0,remaining),length};
}

export function envelopePoints(envelope:AudioEnvelope,length:number,elapsed:number,duration:number) {
  const from=bounded(elapsed,0,length),end=bounded(from+duration,from,length);
  const fi=bounded(envelope.fadeIn,0,length),fo=bounded(envelope.fadeOut,0,length);
  const crossing=fi&&fo?length*fi/(fi+fo):0;
  return [...new Set([from,fi,length-fo,crossing,end].filter(v=>v>=from&&v<=end))]
    .sort((a,b)=>a-b).map(time=>({time:time-from,value:envelopeGain(envelope,time,length)}));
}

export function waveformPeaks(channels:Float32Array[],count=120) {
  const length=channels[0]?.length??0;
  return Array.from({length:count},(_,index)=>{
    let peak=0;const start=Math.floor(index*length/count),end=Math.floor((index+1)*length/count);
    for(const channel of channels)for(let i=start;i<end;i++)peak=Math.max(peak,Math.abs(channel[i]||0));
    return Math.min(1,peak);
  });
}
