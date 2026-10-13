import { envelopeGain, envelopePoints, voiceWindow, type SoundEdit, type VoiceEdit } from './audio-model';

export function scheduleVoice(context:BaseAudioContext, destination:AudioNode, buffer:AudioBuffer, voice:VoiceEdit, videoTime:number, videoEnd:number) {
  const window=voiceWindow(voice,videoTime,videoEnd);
  if(window.duration<=0)return null;
  const source=context.createBufferSource(),gain=context.createGain();source.buffer=buffer;
  source.connect(gain);gain.connect(destination);
  const start=context.currentTime+window.delay;
  gain.gain.setValueAtTime(0,context.currentTime);
  const points=envelopePoints(voice,window.length,window.elapsed,window.duration);
  points.forEach((point,index)=>{
    if(index===0)gain.gain.setValueAtTime(point.value,start);
    else gain.gain.linearRampToValueAtTime(point.value,start+point.time);
  });
  source.start(start,window.offset,window.duration);
  source.onended=()=>{source.disconnect();gain.disconnect();};
  return source;
}

export class PreviewSound {
  readonly context=new AudioContext();
  private source:MediaElementAudioSourceNode;
  private gain:GainNode;
  private voice:AudioBufferSourceNode|null=null;
  constructor(private video:HTMLVideoElement) {
    this.source=this.context.createMediaElementSource(video);this.gain=this.context.createGain();
    this.source.connect(this.gain);this.gain.connect(this.context.destination);
  }
  async resume(){await this.context.resume();}
  update(sound:SoundEdit,start:number,end:number){this.gain.gain.setValueAtTime(envelopeGain(sound.source,this.video.currentTime-start,end-start),this.context.currentTime);}
  sync(sound:SoundEdit,buffer:AudioBuffer|null,start:number,end:number){
    this.stop();this.update(sound,start,end);
    if(!this.video.paused&&!this.video.seeking&&this.video.readyState>=3&&buffer&&sound.voice)this.voice=scheduleVoice(this.context,this.context.destination,buffer,sound.voice,this.video.currentTime,end);
  }
  stop(){try{this.voice?.stop();}catch{}this.voice=null;}
  dispose(){this.stop();this.source.disconnect();this.gain.disconnect();void this.context.close();}
}

export async function decodeVoice(blob:Blob) {
  const context=new AudioContext();
  try{return await context.decodeAudioData(await blob.arrayBuffer());}finally{await context.close();}
}

export async function mixCapture(display:MediaStream,microphone:MediaStream|null) {
  const tracks=[...display.getAudioTracks(),...(microphone?.getAudioTracks()??[])];
  if(!tracks.length)return {stream:display,close:()=>{display.getTracks().forEach(t=>t.stop());microphone?.getTracks().forEach(t=>t.stop());}};
  const context=new AudioContext(),destination=context.createMediaStreamDestination();
  try {
    for(const track of tracks){const input=context.createMediaStreamSource(new MediaStream([track]));input.connect(destination);}
    await context.resume();
    return {stream:new MediaStream([...display.getVideoTracks(),...destination.stream.getAudioTracks()]),close:()=>{display.getTracks().forEach(t=>t.stop());microphone?.getTracks().forEach(t=>t.stop());destination.stream.getTracks().forEach(t=>t.stop());void context.close();}};
  }catch(error){await context.close();throw error;}
}
