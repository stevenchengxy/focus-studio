import { AudioLines, Mic, Square, Upload, X } from 'lucide-react';
import { bounded, type SoundEdit } from './audio-model';

interface Props {
  sound:SoundEdit; onChange:(sound:SoundEdit)=>void; onDraft:(sound:SoundEdit)=>void; onBegin:()=>void; onEnd:()=>void; disabled:boolean; hasVideo:boolean;
  voiceName:string; voiceDuration:number; peaks:number[]; recording:boolean; busy:boolean; level:number;
  onImport:()=>void; onRecord:()=>void; onStop:()=>void; duration:number;
}
export function AudioPanel(p:Props){
  const voice=p.sound.voice;
  function number(label:string,value:number,max:number,onChange:(value:number)=>void,min=0){return <label>{label}<input aria-label={label} type="number" min={min} max={max} step={.1} value={Math.round(value*100)/100} onChange={e=>onChange(bounded(Number(e.target.value),min,max))}/></label>;}
  return <section className="studio-sound-panel" aria-label="Sound editor">
    <div className="studio-sound-heading"><h2><AudioLines size={17}/> Sound</h2><span>Preview and export together</span></div>
    <div className="studio-sound-grid">
      <fieldset disabled={p.disabled||!p.hasVideo}><legend>Original audio</legend>
        <label className="studio-sound-level">Volume <output>{Math.round(p.sound.source.volume*100)}%</output><input aria-label="Original audio volume" type="range" min={0} max={2} step={.05} value={p.sound.source.volume} onPointerDown={p.onBegin} onPointerUp={p.onEnd} onPointerCancel={p.onEnd} onKeyDown={p.onBegin} onKeyUp={p.onEnd} onBlur={p.onEnd} onChange={e=>p.onDraft({...p.sound,source:{...p.sound.source,volume:Number(e.target.value)}})}/></label>
        <div className="studio-sound-fields">{number('Fade in (s)',p.sound.source.fadeIn,Math.min(5,p.duration),v=>p.onChange({...p.sound,source:{...p.sound.source,fadeIn:v}}))}{number('Fade out (s)',p.sound.source.fadeOut,Math.min(5,p.duration),v=>p.onChange({...p.sound,source:{...p.sound.source,fadeOut:v}}))}</div>
      </fieldset>
      <div className="studio-voice-track"><div className="studio-voice-header"><h3><Mic size={15}/> {voice?p.voiceName:'Voiceover / music'}</h3>{voice&&<button aria-label="Remove voiceover from edit" disabled={p.disabled} onClick={()=>p.onChange({...p.sound,voice:null})}><X size={14}/></button>}</div>
        {p.recording?<div className="studio-voice-recording" role="status"><span className="studio-record-dot"/><span>Recording voiceover</span><meter aria-label="Microphone input level" value={p.level} min={0} max={1}/><button onClick={p.onStop}><Square size={12} fill="currentColor"/> Stop</button></div>:<div className="studio-voice-actions"><button disabled={p.disabled||!p.hasVideo} onClick={p.onRecord}><Mic size={14}/> {p.busy?'Preparing audio…':'Record voiceover'}</button><button disabled={p.disabled||!p.hasVideo} onClick={p.onImport}><Upload size={14}/> Import audio</button></div>}
        {voice&&<fieldset disabled={p.disabled} className="studio-voice-settings"><legend className="sr-only">Voiceover settings</legend>
          <div className="studio-waveform" role="img" aria-label={`Audio waveform, ${p.voiceDuration.toFixed(1)} seconds`}>
            {p.peaks.map((peak,i)=><i key={i} style={{height:`${Math.max(3,peak*100)}%`,opacity:i/p.peaks.length>=voice.inPoint/p.voiceDuration&&i/p.peaks.length<=voice.outPoint/p.voiceDuration?1:.2}}/>)}</div>
          <div className="studio-sound-fields">{number('Start at (s)',voice.offset,p.duration,v=>p.onChange({...p.sound,voice:{...voice,offset:v}}))}{number('Audio in (s)',voice.inPoint,Math.max(0,voice.outPoint-.05),v=>p.onChange({...p.sound,voice:{...voice,inPoint:v}}))}{number('Audio out (s)',voice.outPoint,p.voiceDuration,v=>p.onChange({...p.sound,voice:{...voice,outPoint:v}}),voice.inPoint+.05)}</div>
          <label className="studio-sound-level">Volume <output>{Math.round(voice.volume*100)}%</output><input aria-label="Voiceover volume" type="range" min={0} max={2} step={.05} value={voice.volume} onPointerDown={p.onBegin} onPointerUp={p.onEnd} onPointerCancel={p.onEnd} onKeyDown={p.onBegin} onKeyUp={p.onEnd} onBlur={p.onEnd} onChange={e=>p.onDraft({...p.sound,voice:{...voice,volume:Number(e.target.value)}})}/></label>
          <div className="studio-sound-fields">{number('Voice fade in (s)',voice.fadeIn,Math.min(5,voice.outPoint-voice.inPoint),v=>p.onChange({...p.sound,voice:{...voice,fadeIn:v}}))}{number('Voice fade out (s)',voice.fadeOut,Math.min(5,voice.outPoint-voice.inPoint),v=>p.onChange({...p.sound,voice:{...voice,fadeOut:v}}))}</div>
        </fieldset>}
        {!voice&&!p.recording&&<p className="studio-control-hint">Records from the playhead. Use headphones; the video stays paused.</p>}
      </div>
    </div>
  </section>;
}
