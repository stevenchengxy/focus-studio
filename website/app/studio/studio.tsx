"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { ArrowLeft, ArrowUpRight, AudioLines, Check, Circle, Download, Focus, Info, Maximize, Mic, Monitor, MousePointer2, Pause, Play, RotateCcw, Scan, Scissors, Square, Upload, X } from "lucide-react";
import { Brand } from "@/components/marketing/focus-home";
import { ThemeToggle } from "@/components/theme/theme-toggle";
import { readPendingExport, savePendingExport, removePendingExport, readReservationJob, saveReservationJob, removeReservationJob } from "./local-export-store";
import type { PendingExport, ExportReservationJob } from "./local-export-store";
import { defaultSound, envelopeGain, waveformPeaks, type SoundEdit } from './audio-model';
import { AudioPanel } from './audio-panel';
import { studioRequest, type DesktopCapabilities } from './desktop-bridge';
import { decodeVoice, mixCapture, PreviewSound, scheduleVoice } from './audio-engine';

type Effect = "none" | "zoom" | "spotlight";
type Phase = "empty" | "recording" | "paused" | "editing" | "exporting";
interface Point { x: number; y: number; }
interface Account { authenticated: boolean; account?: {id:string}; entitlement?: { canExport: boolean; freeExportsRemaining: number; plan: string; }; billingConfigured?: boolean; }
interface Reservation { exportId: string; status: "reserved" | "committed" | "released" | "expired"; mode: "trial" | "subscription"; expiresAt: number; }
interface Edit { inPoint: number; outPoint: number; effect: Effect; point: Point; sound: SoundEdit; }
const MAX_SECONDS = 120;
const MAX_BYTES = 250 * 1024 * 1024;
const frameWidth = 1280;
const frameHeight = 720;

function clamp(n: number, lo: number, hi: number) { return Math.max(lo, Math.min(hi, n)); }
function time(n: number) { const safe = Number.isFinite(n) ? n : 0; return `${Math.floor(safe / 60).toString().padStart(2, "0")}:${(safe % 60).toFixed(1).padStart(4, "0")}`; }
function mimeType(withAudio = true) {
  if (typeof MediaRecorder === "undefined") return "";
  const options = withAudio ? ["video/webm;codecs=vp9,opus", "video/webm;codecs=vp8,opus", "video/webm", "video/mp4"] : ["video/webm;codecs=vp9", "video/webm;codecs=vp8", "video/webm", "video/mp4"];
  return options.find((candidate) => MediaRecorder.isTypeSupported(candidate)) || "";
}
function fitRect(video: HTMLVideoElement) {
  const w = video.videoWidth || frameWidth, h = video.videoHeight || frameHeight;
  const scale = Math.min(frameWidth / w, frameHeight / h);
  return {x:(frameWidth - w * scale) / 2, y:(frameHeight - h * scale) / 2, width:w * scale, height:h * scale};
}
function drawFrame(canvas: HTMLCanvasElement, video: HTMLVideoElement, edit: Edit) {
  const ctx = canvas.getContext("2d", {alpha:false});
  if (!ctx || video.readyState < 2) return;
  const rect = fitRect(video);
  const length = Math.max(.04, edit.outPoint - edit.inPoint);
  const position = clamp(video.currentTime - edit.inPoint, 0, length);
  const ramp = Math.min(.55, length / 3);
  const t = clamp(Math.min(position / ramp, (length - position) / ramp), 0, 1);
  const strength = t * t * (3 - 2 * t);
  ctx.fillStyle = "#19171f";
  ctx.fillRect(0, 0, frameWidth, frameHeight);
  if (edit.effect === "zoom") {
    const scale = 1 + .55 * strength;
    const anchorX = rect.x + edit.point.x * rect.width;
    const anchorY = rect.y + edit.point.y * rect.height;
    const offsetX = clamp(frameWidth / 2 - anchorX * scale, frameWidth * (1 - scale), 0);
    const offsetY = clamp(frameHeight / 2 - anchorY * scale, frameHeight * (1 - scale), 0);
    ctx.save();ctx.translate(offsetX,offsetY);ctx.scale(scale,scale);
    ctx.drawImage(video, rect.x,rect.y,rect.width,rect.height);ctx.restore();
  } else {
    ctx.drawImage(video,rect.x,rect.y,rect.width,rect.height);
    if (edit.effect === "spotlight") {
      const rw = rect.width * .35, rh = rect.height * .35;
      const x = clamp(rect.x + edit.point.x * rect.width - rw / 2,rect.x,rect.x + rect.width - rw);
      const y = clamp(rect.y + edit.point.y * rect.height - rh / 2,rect.y,rect.y + rect.height - rh);
      ctx.save();ctx.fillStyle = `rgba(14,10,22,${.62 * strength})`;
      ctx.beginPath();ctx.rect(0,0,frameWidth,frameHeight);ctx.roundRect(x,y,rw,rh,12);ctx.fill("evenodd");
      ctx.strokeStyle=`rgba(235,224,255,${.6 * strength})`;ctx.lineWidth=2;ctx.beginPath();ctx.roundRect(x,y,rw,rh,12);ctx.stroke();ctx.restore();
    }
  }
}
async function api<T>(url: string, body?: unknown): Promise<T> {
  const response = await studioRequest(url,body);
  const data = await response.json() as T & {error?: string | {message?:string}};
  if (!response.ok) {
    const message = typeof data.error === "string" ? data.error : data.error?.message;
    throw new Error(response.status === 401 ? "Sign in to use your free export. Your video stays in this tab." : message || "The request could not be completed. Please try again.");
  }
  return data;
}
async function acquireExportLock():Promise<()=>void> {
  if(!navigator.locks)throw new Error("This browser cannot safely coordinate local exports. Use a current Chrome, Edge, Firefox or Safari browser.");
  return new Promise((resolve,reject)=>{
    navigator.locks.request("focus-studio-local-export",{ifAvailable:true},async lock=>{
      if(!lock){reject(new Error("Another Browser Studio tab is exporting. Return to that tab or wait for it to finish."));return;}
      await new Promise<void>(release=>resolve(release));
    }).catch(reject);
  });
}
async function ready(video: HTMLVideoElement) {
  if (video.readyState >= 2) return;
  await new Promise<void>((resolve,reject) => {
    const timeout = setTimeout(() => {cleanup(); reject(new Error("This video could not be loaded."));},15000);
    const cleanup = () => {clearTimeout(timeout);video.removeEventListener("loadeddata",loaded);video.removeEventListener("error",failed);};
    const loaded = () => {cleanup();resolve();}; const failed = () => {cleanup();reject(new Error("This video format is not supported by your browser."));};
    video.addEventListener("loadeddata",loaded);video.addEventListener("error",failed);video.load();
  });
}
async function seek(video: HTMLVideoElement, position: number) {
  if (Math.abs(video.currentTime - position) < .001) return;
  await new Promise<void>((resolve,reject) => {
    const timer = setTimeout(() => {video.removeEventListener("seeked",finish);reject(new Error("Could not seek to the selected frame."));},15000);
    const finish = () => {clearTimeout(timer);resolve();};video.addEventListener("seeked",finish,{once:true});video.currentTime=position;
  });
}

export function BrowserStudio() {
  const [phase,setPhase] = useState<Phase>("empty");
  const [source,setSource] = useState("");
  const [filename,setFilename] = useState("Untitled demo");
  const [duration,setDuration] = useState(0);
  const [position,setPosition] = useState(0);
  const [edit,setEdit] = useState<Edit>({inPoint:0,outPoint:0,effect:"none",point:{x:.5,y:.5},sound:defaultSound()});
  const [undo,setUndo] = useState<Edit[]>([]);
  const [redo,setRedo] = useState<Edit[]>([]);
  const [playing,setPlaying] = useState(false);
  const [startingCapture,setStartingCapture] = useState(false);
  const [loadingSample,setLoadingSample] = useState(false);
  const startingCaptureRef=useRef(false);
  const [includeAudio,setIncludeAudio] = useState(true);
  const [desktop,setDesktop] = useState<DesktopCapabilities|null>(null);
  const [connectingAccount,setConnectingAccount] = useState(false);
  const [includeMic,setIncludeMic] = useState(false);
  const [cleanVoice,setCleanVoice] = useState(true);
  const [micDevice,setMicDevice] = useState('');
  const [micDevices,setMicDevices] = useState<MediaDeviceInfo[]>([]);
  const voiceAssets=useRef(new Map<string,{buffer:AudioBuffer;name:string;peaks:number[]}>());
  const [voiceRecording,setVoiceRecording] = useState(false);
  const [voiceBusy,setVoiceBusy] = useState(false);
  const [voiceLevel,setVoiceLevel] = useState(0);
  const voiceInput=useRef<HTMLInputElement>(null);
  const selectedVoice=()=>voiceAssets.current.get(editRef.current.sound.voice?.assetId??'');
  const voiceRecorder=useRef<MediaRecorder|null>(null),voiceCleanup=useRef<(()=>void)|null>(null);
  const voiceStart=useRef(0),voiceOffset=useRef(0),voiceGuard=useRef(false);
  const previewSound=useRef<PreviewSound|null>(null),captureCleanup=useRef<(()=>void)|null>(null);
  const [elapsed,setElapsed] = useState(0);
  const [message,setMessage] = useState("");
  const [account,setAccount] = useState<Account | null>(null);
  const [progress,setProgress] = useState(0);
  const [support,setSupport] = useState({record:false,export:false});
  const [lastDownload,setLastDownload] = useState<{url:string,name:string,exportId:string} | null>(null);
  const [pendingExport,setPendingExport] = useState<PendingExport | null>(null);
  const pendingRef=useRef<PendingExport | null>(null);
  const [reservationJob,setReservationJob]=useState<ExportReservationJob|null>(null);
  const reservationJobRef=useRef<ExportReservationJob|null>(null);
  const cancelReason=useRef("Export cancelled. Your allowance has not been used.");
  const [capturedAudio,setCapturedAudio] = useState<boolean | null>(null);
  const videoRef=useRef<HTMLVideoElement>(null), canvasRef=useRef<HTMLCanvasElement>(null), fileRef=useRef<HTMLInputElement>(null);
  const mediaRef=useRef<MediaRecorder | null>(null), streamRef=useRef<MediaStream | null>(null), chunksRef=useRef<Blob[]>([]), bytesRef=useRef(0);
  const recordClock=useRef({start:0,carried:0}), sourceRef=useRef(""), downloadRef=useRef(""), recordedDuration=useRef(0);
  const reservationRef=useRef<string | null>(null), abortExport=useRef(false), exportingRef=useRef(false);
  const editRef=useRef(edit), originalDraft=useRef<Edit | null>(null), mounted=useRef(true);
  const fetchAccount=useCallback(() => {studioRequest("/api/account").then(r=>r.json()).then(data=>{if(mounted.current)setAccount(data as Account);}).catch(()=>{if(mounted.current)setAccount({authenticated:false});});},[]);

  useEffect(() => {
    window.focusDesktop?.setActivity?.({
      recording: startingCapture || phase === 'recording' || phase === 'paused' || voiceRecording || voiceBusy,
      exporting: phase === 'exporting' || playing,
    });
  }, [startingCapture, phase, voiceRecording, voiceBusy, playing]);

  useEffect(() => {
    mounted.current=true;fetchAccount();
    const desktopBridge=window.focusDesktop;desktopBridge?.getCapabilities().then(value=>{if(mounted.current){setDesktop(value);if(value.systemAudio==='unavailable')setIncludeAudio(false);}}).catch(()=>{});const unsubscribeAccount=desktopBridge?.onAccountChanged(fetchAccount);
    void refreshMicrophones();
    Promise.all([readPendingExport(),readReservationJob()]).then(([pending,job])=>{
      if(!mounted.current||exportingRef.current)return;
      if(pending?.blob instanceof Blob){pendingRef.current=pending;setPendingExport(pending);setMessage("A rendered video is saved on this device. Finish its export confirmation to recover your download.");}
      if(job){reservationJobRef.current=job;setReservationJob(job);}
    }).catch(()=>{});
    const leaveGuard=(event:BeforeUnloadEvent)=>{if(pendingRef.current||exportingRef.current||sourceRef.current||voiceGuard.current||startingCaptureRef.current||mediaRef.current?.state==="recording"||mediaRef.current?.state==="paused"){event.preventDefault();event.returnValue="";}};window.addEventListener("beforeunload",leaveGuard);
    if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(()=>{});
    setSupport({record:!!navigator.mediaDevices?.getDisplayMedia && !!mimeType(),export:typeof HTMLCanvasElement.prototype.captureStream === "function" && !!mimeType() && !!navigator.locks});
    const onFocus=()=>{fetchAccount();if(!exportingRef.current)readPendingExport().then(saved=>{if(saved&&!saved.confirmed&&mounted.current&&!exportingRef.current){pendingRef.current=saved;setPendingExport(saved);}}).catch(()=>{});};window.addEventListener("focus",onFocus);
    return () => {mounted.current=false;unsubscribeAccount?.();abortExport.current=true;captureCleanup.current?.();voiceCleanup.current?.();previewSound.current?.dispose();previewSound.current=null;streamRef.current?.getTracks().forEach(t=>t.stop());if(mediaRef.current && mediaRef.current.state!=="inactive")mediaRef.current.stop();if(sourceRef.current)URL.revokeObjectURL(sourceRef.current);if(downloadRef.current)URL.revokeObjectURL(downloadRef.current);if(reservationRef.current&&!pendingRef.current)studioRequest(`/api/exports/${reservationRef.current}/release`,{}).catch(()=>{});window.removeEventListener("focus",onFocus);window.removeEventListener("beforeunload",leaveGuard);};
  },[fetchAccount]);
  useEffect(()=>{editRef.current=edit;},[edit]);
  useEffect(()=>{
    if(phase!=="exporting")return;
    const stopOnHidden=()=>{if(document.hidden){cancelReason.current="Export stopped because the tab became hidden. Keep this tab active and retry; your allowance was not used for the interrupted render.";abortExport.current=true;}};
    document.addEventListener("visibilitychange",stopOnHidden);return()=>document.removeEventListener("visibilitychange",stopOnHidden);
  },[phase]);
  useEffect(()=>{
    if(phase!=="recording" && phase!=="paused")return;
    const timer=setInterval(()=>{
      const seconds=recordClock.current.carried+(phase==="recording"?(performance.now()-recordClock.current.start)/1000:0);
      setElapsed(seconds);recordedDuration.current=seconds;
      if(seconds>=MAX_SECONDS && mediaRef.current?.state!=="inactive"){setMessage("The 2-minute beta recording limit was reached. Your take is ready to edit.");mediaRef.current?.stop();}
    },150);return()=>clearInterval(timer);
  },[phase]);
  useEffect(()=>{
    const video=videoRef.current,canvas=canvasRef.current;if(!video||!canvas||!source)return;
    let frame=0;
    const draw=()=>{const current=editRef.current;drawFrame(canvas,video,current);previewSound.current?.update(current.sound,current.inPoint,current.outPoint);if(!video.paused&&!video.ended)frame=requestAnimationFrame(draw);};
    const onPlay=()=>{cancelAnimationFrame(frame);draw();};
    const onFrame=()=>drawFrame(canvas,video,editRef.current);
    video.addEventListener("play",onPlay);video.addEventListener("seeked",onFrame);video.addEventListener("loadeddata",onFrame);video.addEventListener("pause",onFrame);onFrame();
    return()=>{cancelAnimationFrame(frame);video.removeEventListener("play",onPlay);video.removeEventListener("seeked",onFrame);video.removeEventListener("loadeddata",onFrame);video.removeEventListener("pause",onFrame);};
  },[source]);
  useEffect(()=>{if(canvasRef.current&&videoRef.current)drawFrame(canvasRef.current,videoRef.current,edit);},[edit]);
  useEffect(()=>{previewSound.current?.sync(edit.sound,selectedVoice()?.buffer??null,edit.inPoint,edit.outPoint);},[edit]);
  useEffect(()=>{
    const video=videoRef.current;if(!video)return;
    const sync=()=>{const e=editRef.current;previewSound.current?.sync(e.sound,selectedVoice()?.buffer??null,e.inPoint,e.outPoint);};
    const suspend=()=>previewSound.current?.stop();
    video.addEventListener('playing',sync);video.addEventListener('seeked',sync);video.addEventListener('pause',sync);video.addEventListener('waiting',suspend);video.addEventListener('seeking',suspend);
    return()=>{video.removeEventListener('playing',sync);video.removeEventListener('seeked',sync);video.removeEventListener('pause',sync);video.removeEventListener('waiting',suspend);video.removeEventListener('seeking',suspend);};
  },[]);
  useEffect(()=>{
    const handler=(event:KeyboardEvent)=>{const el=event.target as HTMLElement;if(el instanceof HTMLInputElement||el instanceof HTMLTextAreaElement||el instanceof HTMLButtonElement||el instanceof HTMLAnchorElement||el instanceof HTMLSelectElement)return;if(event.code==="Space"&&phase==="editing"&&!voiceGuard.current){event.preventDefault();togglePlay();}};
    window.addEventListener("keydown",handler);return()=>window.removeEventListener("keydown",handler);
  });

  function useSource(blob:Blob,name:string,fallbackDuration=0) {
    videoRef.current?.pause();setPlaying(false);
    if(sourceRef.current)URL.revokeObjectURL(sourceRef.current);
    const url=URL.createObjectURL(blob);sourceRef.current=url;recordedDuration.current=fallbackDuration;
    voiceAssets.current.clear();
    setSource(url);setFilename(name);setDuration(0);setPosition(0);setUndo([]);setRedo([]);setEdit({inPoint:0,outPoint:0,effect:"none",point:{x:.5,y:.5},sound:defaultSound()});setPhase("editing");
  }
  function updateEdit(next:Edit) {setUndo(old=>[...old.slice(-39),edit]);setRedo([]);setEdit(next);}
  function undoEdit(){const previous=undo.at(-1);if(!previous)return;setRedo(old=>[...old,edit]);setUndo(old=>old.slice(0,-1));setEdit(previous);}
  function redoEdit(){const next=redo.at(-1);if(!next)return;setUndo(old=>[...old,edit]);setRedo(old=>old.slice(0,-1));setEdit(next);}
  function beginRange(){if(!originalDraft.current)originalDraft.current=editRef.current;}
  function finishRange(){const original=originalDraft.current;if(original&&JSON.stringify(original)!==JSON.stringify(editRef.current)){setUndo(old=>[...old.slice(-39),original]);setRedo([]);}originalDraft.current=null;}
  function setPositionTo(value:number){const video=videoRef.current;if(!video)return;video.currentTime=clamp(value,0,duration);setPosition(value);}
  async function togglePlay(){const video=videoRef.current;if(!video||voiceGuard.current)return;if(video.paused){if(video.currentTime<edit.inPoint||video.currentTime>=edit.outPoint-.04)video.currentTime=edit.inPoint;try{if(!previewSound.current)previewSound.current=new PreviewSound(video);await previewSound.current.resume();previewSound.current.update(edit.sound,edit.inPoint,edit.outPoint);await video.play();}catch{setMessage("Your browser could not play this video.");}}else video.pause();}

  async function refreshMicrophones(){
    try{const devices=await navigator.mediaDevices.enumerateDevices();if(mounted.current)setMicDevices(devices.filter(d=>d.kind==='audioinput'));}catch{}
  }
  function micConstraints():MediaTrackConstraints {return {deviceId:micDevice?{exact:micDevice}:undefined,echoCancellation:cleanVoice,noiseSuppression:cleanVoice,autoGainControl:cleanVoice};}
  async function startRecording(){
    if(!support.record||phase==='recording'||phase==='paused'||phase==='exporting'||startingCaptureRef.current||voiceGuard.current)return;
    startingCaptureRef.current=true;setStartingCapture(true);setMessage('');videoRef.current?.pause();
    let display:MediaStream|null=null,microphone:MediaStream|null=null;
    try{
      display=await navigator.mediaDevices.getDisplayMedia({video:{frameRate:{ideal:30,max:30}},audio:includeAudio});
      if(!mounted.current){display.getTracks().forEach(t=>t.stop());return;}
      if(includeMic){microphone=await navigator.mediaDevices.getUserMedia({audio:micConstraints(),video:false});await refreshMicrophones();}
      if(!mounted.current){display.getTracks().forEach(t=>t.stop());microphone?.getTracks().forEach(t=>t.stop());return;}
      const sharedAudio=display.getAudioTracks().length>0;
      const mixed=await mixCapture(display,microphone);if(!mounted.current){mixed.close();return;}captureCleanup.current=mixed.close;
      const stream=mixed.stream;streamRef.current=stream;setCapturedAudio(stream.getAudioTracks().length>0);
      if(includeAudio&&!sharedAudio)setMessage('This capture source did not share system audio.'+(microphone?' Microphone narration is being recorded.':' Select a supported tab or source to include it.'));
      const recorder=new MediaRecorder(stream,{mimeType:mimeType(stream.getAudioTracks().length>0),videoBitsPerSecond:6_000_000});
      mediaRef.current=recorder;chunksRef.current=[];bytesRef.current=0;recordClock.current={start:performance.now(),carried:0};recordedDuration.current=0;setElapsed(0);
      recorder.ondataavailable=event=>{if(event.data.size){chunksRef.current.push(event.data);bytesRef.current+=event.data.size;if(bytesRef.current>MAX_BYTES&&recorder.state!=='inactive')stopRecording();}};
      recorder.onerror=()=>{setMessage('Recording was interrupted. Recovering the captured portion.');if(recorder.state!=='inactive')recorder.stop();mixed.close();};
      recorder.onstop=()=>{
        mixed.close();captureCleanup.current=null;streamRef.current=null;
        const blob=new Blob(chunksRef.current,{type:recorder.mimeType});if(!mounted.current)return;
        if(!blob.size){setMessage('No video was captured. Please try again.');setPhase(sourceRef.current?'editing':'empty');return;}
        useSource(blob,`Recording ${new Date().toLocaleDateString()}`,Math.min(MAX_SECONDS,recordedDuration.current||recordClock.current.carried));
      };
      display.getVideoTracks()[0].addEventListener('ended',stopRecording,{once:true});recorder.start(250);setPhase('recording');
    }catch(error){captureCleanup.current?.();captureCleanup.current=null;display?.getTracks().forEach(t=>t.stop());microphone?.getTracks().forEach(t=>t.stop());streamRef.current=null;setMessage((error as DOMException).name==='NotAllowedError'?'Recording permission was not granted. Nothing is being recorded.':'Screen or microphone capture could not start. Check your selected device and retry.');}
    finally{startingCaptureRef.current=false;if(mounted.current)setStartingCapture(false);}
  }

  async function installVoice(blob:Blob,name:string,offset:number,recordingLimit?:number){
    if(blob.size>25*1024*1024)throw new Error('Choose an audio file smaller than 25 MB.');
    let buffer=await decodeVoice(blob);if(!mounted.current)return;
    if(recordingLimit!==undefined&&buffer.duration>recordingLimit){const length=Math.max(1,Math.floor(recordingLimit*buffer.sampleRate));const trimmed=new AudioBuffer({length,numberOfChannels:buffer.numberOfChannels,sampleRate:buffer.sampleRate});for(let i=0;i<buffer.numberOfChannels;i++)trimmed.copyToChannel(buffer.getChannelData(i).subarray(0,length),i);buffer=trimmed;}
    if(buffer.duration+1/buffer.sampleRate<.1||buffer.duration>MAX_SECONDS)throw new Error('Audio clips must be between 0.1 seconds and 2 minutes long.');
    let memory=buffer.length*buffer.numberOfChannels*4;for(const asset of voiceAssets.current.values())memory+=asset.buffer.length*asset.buffer.numberOfChannels*4;
    if(memory>128*1024*1024)throw new Error('This edit has reached its 128 MB decoded-audio limit. Finish this video before importing more audio.');
    const assetId=crypto.randomUUID();voiceAssets.current.set(assetId,{buffer,name,peaks:waveformPeaks(Array.from({length:buffer.numberOfChannels},(_,i)=>buffer.getChannelData(i)))});
    updateEdit({...edit,sound:{...edit.sound,voice:{assetId,offset:clamp(offset,0,Math.max(0,edit.outPoint-.1)),inPoint:0,outPoint:buffer.duration,volume:1,fadeIn:.08,fadeOut:.15}}});
    setMessage('Audio added. Set its timing below, then preview with your video.');
  }
  async function importVoice(file?:File){
    if(!file||voiceGuard.current||startingCaptureRef.current||exportingRef.current||phase!=='editing')return;voiceGuard.current=true;setVoiceBusy(true);videoRef.current?.pause();
    try{await installVoice(file,file.name.replace(/\.[^.]+$/,''),position);}catch(error){setMessage(error instanceof Error?error.message:'This audio file could not be decoded.');}
    finally{voiceGuard.current=false;if(mounted.current)setVoiceBusy(false);}
  }
  async function recordVoice(){
    if(voiceGuard.current||startingCaptureRef.current||exportingRef.current||phase!=='editing'||!duration)return;
    voiceGuard.current=true;setVoiceBusy(true);videoRef.current?.pause();setMessage('');
    let stream:MediaStream|null=null,context:AudioContext|null=null,timer:ReturnType<typeof setInterval>|undefined;
    try{
      stream=await navigator.mediaDevices.getUserMedia({audio:micConstraints(),video:false});await refreshMicrophones();
      if(!mounted.current){stream.getTracks().forEach(t=>t.stop());return;}
      const mime=['audio/webm;codecs=opus','audio/webm','audio/mp4'].find(t=>MediaRecorder.isTypeSupported(t));
      if(!mime)throw new Error('Audio recording is unavailable here. Import an audio file instead.');
      context=new AudioContext();await context.resume();if(!mounted.current){stream.getTracks().forEach(t=>t.stop());await context.close();return;}const analyser=context.createAnalyser();analyser.fftSize=256;
      context.createMediaStreamSource(stream).connect(analyser);const samples=new Float32Array(analyser.fftSize);
      const recorder=new MediaRecorder(stream,{mimeType:mime});voiceRecorder.current=recorder;
      const chunks:Blob[]=[];let size=0;voiceOffset.current=clamp(position,edit.inPoint,Math.max(edit.inPoint,edit.outPoint-.1));voiceStart.current=performance.now();const recordingLimit=Math.min(MAX_SECONDS,edit.outPoint-voiceOffset.current);
      const cleanup=()=>{if(timer)clearInterval(timer);stream?.getTracks().forEach(t=>t.stop());void context?.close().catch(()=>{});};voiceCleanup.current=cleanup;
      recorder.ondataavailable=event=>{if(event.data.size){chunks.push(event.data);size+=event.data.size;if(size>25*1024*1024&&recorder.state!=='inactive')recorder.stop();}};
      recorder.onerror=()=>{setMessage('Microphone recording was interrupted.');if(recorder.state!=='inactive')recorder.stop();};
      recorder.onstop=async()=>{cleanup();voiceCleanup.current=null;voiceRecorder.current=null;if(!mounted.current)return;setVoiceRecording(false);setVoiceLevel(0);setVoiceBusy(true);
        try{const blob=new Blob(chunks,{type:mime});if(!blob.size)throw new Error('No voice audio was captured.');await installVoice(blob,'Voiceover',voiceOffset.current,recordingLimit);}catch(error){setMessage(error instanceof Error?error.message:'Voiceover could not be decoded.');}finally{voiceGuard.current=false;if(mounted.current)setVoiceBusy(false);}};
      timer=setInterval(()=>{analyser.getFloatTimeDomainData(samples);let peak=0;for(const value of samples)peak=Math.max(peak,Math.abs(value));if(mounted.current)setVoiceLevel(peak);if(performance.now()-voiceStart.current>=recordingLimit*1000&&recorder.state!=='inactive')recorder.stop();},80);
      recorder.start(250);setVoiceRecording(true);setVoiceBusy(false);
    }catch(error){if(timer)clearInterval(timer);stream?.getTracks().forEach(t=>t.stop());void context?.close().catch(()=>{});voiceGuard.current=false;if(mounted.current){setVoiceBusy(false);setMessage((error as DOMException).name==='NotAllowedError'?'Microphone access was not granted.':error instanceof Error?error.message:'Microphone could not start.');}}
  }
  function pauseRecording(){const recorder=mediaRef.current;if(!recorder)return;if(recorder.state==="recording"){recordClock.current.carried+=(performance.now()-recordClock.current.start)/1000;recorder.pause();setPhase("paused");}else if(recorder.state==="paused"){recordClock.current.start=performance.now();recorder.resume();setPhase("recording");}}
  function stopRecording(){const recorder=mediaRef.current;if(!recorder||recorder.state==="inactive")return;if(recorder.state==="recording")recordClock.current.carried+=(performance.now()-recordClock.current.start)/1000;recordedDuration.current=recordClock.current.carried;recorder.stop();}
  function importFile(file?:File){if(!file||startingCaptureRef.current||voiceGuard.current)return;if(!file.type.startsWith("video/")){setMessage("Choose a video file supported by your browser.");return;}if(file.size>MAX_BYTES){setMessage("Browser Studio beta accepts files up to 250 MB. Use the Mac app for larger projects.");return;}setCapturedAudio(null);setMessage("");useSource(file,file.name.replace(/\.[^.]+$/,""));}
  async function loadSample(){
    if(startingCaptureRef.current||exportingRef.current||loadingSample)return;
    setLoadingSample(true);setMessage("");
    try{const response=await fetch("/media/focus-studio-demo.mp4");if(!response.ok)throw new Error("The sample could not be loaded. Please try again.");const blob=await response.blob();if(!mounted.current)return;useSource(blob,"Focus Studio effect sample");setCapturedAudio(null);setMessage("You’re editing illustrative sample footage from the Focus Studio renderer. Try trimming or adding your own focus effect.");}
    catch(error){if(mounted.current)setMessage(error instanceof Error?error.message:"The sample could not be loaded.");}
    finally{if(mounted.current)setLoadingSample(false);}
  }
  function loadedMetadata(){const video=videoRef.current;if(!video)return;let value=video.duration;if(!Number.isFinite(value)||value<=0)value=recordedDuration.current;if(!value){setMessage("This file does not report a usable duration. Try an MP4 file with duration metadata.");return;}const capped=Math.min(MAX_SECONDS,value);setDuration(capped);setEdit({inPoint:0,outPoint:capped,effect:"none",point:{x:.5,y:.5},sound:defaultSound()});if(value>MAX_SECONDS)setMessage("Browser Studio beta uses the first 2 minutes of this file. Use the Mac app for longer edits.");}
  function choosePoint(event:React.MouseEvent<HTMLCanvasElement>){if(phase!=="editing"||voiceGuard.current||!videoRef.current||!duration)return;const bounds=event.currentTarget.getBoundingClientRect(),rect=fitRect(videoRef.current);const x=(event.clientX-bounds.left)/bounds.width*frameWidth,y=(event.clientY-bounds.top)/bounds.height*frameHeight;if(x<rect.x||x>rect.x+rect.width||y<rect.y||y>rect.y+rect.height)return;videoRef.current.pause();updateEdit({...edit,point:{x:clamp((x-rect.x)/rect.width,0,1),y:clamp((y-rect.y)/rect.height,0,1)}});if(position<=edit.inPoint+.1||position>=edit.outPoint-.1)setPositionTo((edit.inPoint+edit.outPoint)/2);}

  function nudgeFocus(event:React.KeyboardEvent<HTMLCanvasElement>){
    const directions:Record<string,Point>={ArrowLeft:{x:-.02,y:0},ArrowRight:{x:.02,y:0},ArrowUp:{x:0,y:-.02},ArrowDown:{x:0,y:.02}};
    const delta=directions[event.key];if(!delta||phase!=="editing"||voiceGuard.current||!duration)return;event.preventDefault();videoRef.current?.pause();updateEdit({...edit,point:{x:clamp(edit.point.x+delta.x,0,1),y:clamp(edit.point.y+delta.y,0,1)}});if(position<=edit.inPoint+.1||position>=edit.outPoint-.1)setPositionTo((edit.inPoint+edit.outPoint)/2);
  }

  async function confirmDownload(output:PendingExport) {
    if(output.accountId&&output.accountId!==account?.account?.id){setMessage("Sign in to the account that created this saved export, then retry confirmation.");return false;}
    const latest=await readPendingExport();
    if(latest&&latest.exportId!==output.exportId&&!latest.confirmed){pendingRef.current=latest;setPendingExport(latest);throw new Error("A different rendered export is waiting for confirmation. Finish that saved export first.");}
    output={...output,confirmed:!!output.confirmed||!!(latest?.exportId===output.exportId&&latest.confirmed)};
    await savePendingExport(output);
    pendingRef.current=output;setPendingExport(output);
    let lastError:unknown;
    for(let attempt=0;attempt<3;attempt++) {
      try {
        const receipt=await api<Reservation>(`/api/exports/${output.exportId}/commit`,{});
        if(receipt.exportId!==output.exportId||receipt.status!=="committed")throw new Error("The server did not confirm this export. Your rendered video remains saved locally.");
        await savePendingExport({...output,confirmed:true});
        reservationRef.current=null;pendingRef.current=null;setPendingExport(null);
        const activeJob=await readReservationJob();
        if(activeJob&&output.reservationKey===activeJob.idempotencyKey){await removeReservationJob().then(()=>{reservationJobRef.current=null;setReservationJob(null);}).catch(()=>{});}
        const extension=output.blob.type.includes("mp4")?"mp4":"webm";
        if(downloadRef.current)URL.revokeObjectURL(downloadRef.current);
        const url=URL.createObjectURL(output.blob);downloadRef.current=url;
        setLastDownload({url,name:output.name,exportId:output.exportId});setProgress(1);setMessage(`Your ${extension.toUpperCase()} is ready. Download it before closing this tab.`);
        const link=document.createElement("a");link.href=url;link.download=output.name;document.body.appendChild(link);link.click();link.remove();fetchAccount();
        return true;
      } catch(error) {pendingRef.current=output;setPendingExport(output);lastError=error;if(attempt<2)await new Promise(resolve=>setTimeout(resolve,350*(attempt+1)));}
    }
    setMessage(`Your video has rendered and is saved locally in this browser. Export confirmation could not be verified. Retry confirmation; this uses the same export reservation. ${lastError instanceof Error?lastError.message:""}`);
    return false;
  }
  async function retryConfirmation() {
    if(!pendingRef.current||exportingRef.current||startingCaptureRef.current||voiceGuard.current||mediaRef.current?.state==="recording"||mediaRef.current?.state==="paused")return;
    exportingRef.current=true;setPhase("exporting");setProgress(1);
    let unlock:(()=>void)|undefined;
    try {unlock=await acquireExportLock();await confirmDownload(pendingRef.current);}catch(error){setMessage(error instanceof Error?error.message:"Export confirmation could not be completed.");}finally{unlock?.();exportingRef.current=false;setPhase(sourceRef.current?"editing":"empty");}
  }

  async function reserveWithRetry(job:ExportReservationJob) {
    let failure:unknown;
    for(let attempt=0;attempt<3;attempt++) {
      try{return await api<Reservation>("/api/exports/reserve",{idempotencyKey:job.idempotencyKey,projectId:job.projectId});}
      catch(error){failure=error;if(attempt<2)await new Promise(resolve=>setTimeout(resolve,350*(attempt+1)));}
    }
    throw failure;
  }
  async function clearInterruptedReservation() {
    if(exportingRef.current)return;
    exportingRef.current=true;let unlock:(()=>void)|undefined;
    try{
      unlock=await acquireExportLock();
      const job=await readReservationJob(),pending=await readPendingExport();
      if(pending&&!pending.confirmed){pendingRef.current=pending;setPendingExport(pending);setMessage("A rendered video is ready to recover. Finish its export confirmation before clearing reservations.");return;}
      if(!job){reservationJobRef.current=null;setReservationJob(null);return;}
      if(job.accountId&&job.accountId!==account?.account?.id)throw new Error("Sign in to the account that started this export to recover its reservation.");
      const receipt=await reserveWithRetry(job);if(receipt.status==="reserved")await api(`/api/exports/${receipt.exportId}/release`,{});
      await removeReservationJob();reservationJobRef.current=null;setReservationJob(null);setMessage("The interrupted reservation has been cleared. You can export again.");fetchAccount();
    }catch(error){setMessage(error instanceof Error?error.message:"The reservation could not be recovered. Try again when you are online.");}
    finally{unlock?.();exportingRef.current=false;}
  }
  async function clearSavedExport(){
    const displayed=lastDownload;if(!displayed)return;
    const unlock=await acquireExportLock();
    try{const saved=await readPendingExport();if(saved?.exportId===displayed.exportId&&saved.confirmed)await removePendingExport();if(downloadRef.current===displayed.url){URL.revokeObjectURL(displayed.url);downloadRef.current="";}setLastDownload(null);setMessage("This export’s browser preview was removed. Downloads already saved to your device are unchanged.");}
    finally{unlock();}
  }

  async function discardSavedRender(){
    const displayed=pendingExport;if(!displayed||exportingRef.current)return;
    if(!window.confirm("Remove this saved render from this browser? This cannot restore an export already counted by your account."))return;
    let unlock:(()=>void)|undefined;
    try{
      unlock=await acquireExportLock();const saved=await readPendingExport();
      if(!saved){pendingRef.current=null;setPendingExport(null);setMessage("The saved render was already removed in another tab.");return;}
      if(saved.exportId!==displayed.exportId){pendingRef.current=saved;setPendingExport(saved);setMessage("The saved render changed in another tab. Review the current saved export first.");return;}
      let released=false;
      if(saved.accountId===account?.account?.id){try{await api(`/api/exports/${saved.exportId}/release`,{});released=true;}catch{}}
      await removePendingExport();pendingRef.current=null;setPendingExport(null);reservationRef.current=null;
      const job=await readReservationJob();if(released&&job?.idempotencyKey===saved.reservationKey){await removeReservationJob();reservationJobRef.current=null;setReservationJob(null);}
      setMessage("The saved render was removed from this browser. Previously counted exports are unchanged.");fetchAccount();
    }catch(error){setMessage(error instanceof Error?error.message:"The saved render could not be removed.");}finally{unlock?.();}
  }

  async function exportVideo(){
    if(exportingRef.current||startingCaptureRef.current||voiceGuard.current||!source||!duration||!support.export)return;
    if(pendingRef.current){await retryConfirmation();return;}
    if(!account?.authenticated){setMessage("Sign in to use your free export. Open your account in a new tab, then return here; your video stays local.");return;}
    if(!account.entitlement?.canExport){setMessage("Your account has no export available. Check your plan in Account before exporting.");return;}
    exportingRef.current=true;abortExport.current=false;cancelReason.current="Export cancelled. Your allowance has not been used.";setMessage("");setProgress(0);setPhase("exporting");videoRef.current?.pause();
    const AudioContextClass=window.AudioContext;
    let audioContext:AudioContext|null=null,renderVideo:HTMLVideoElement|null=null,renderStream:MediaStream|null=null,renewTimer:ReturnType<typeof setInterval>|undefined;
    let committed=false,unlock:(()=>void)|undefined,sourceGain:GainNode|undefined;const exportAudio:{voice:AudioBufferSourceNode|null}={voice:null};
    try{
      unlock=await acquireExportLock();
      const waiting=await readPendingExport();
      if(waiting&&!waiting.confirmed){pendingRef.current=waiting;setPendingExport(waiting);setMessage("A rendered video is waiting for confirmation. Finish the saved export before creating another.");return;}
      const latestJob=await readReservationJob();reservationJobRef.current=latestJob||null;setReservationJob(latestJob||null);
      if(AudioContextClass){audioContext=new AudioContextClass();await audioContext.resume();}
      const job=reservationJobRef.current||{idempotencyKey:crypto.randomUUID(),projectId:`browser-${crypto.randomUUID()}`,accountId:account.account?.id};
      if(job.accountId&&job.accountId!==account.account?.id)throw new Error("An interrupted export belongs to another account. Sign in to that account to recover it first.");
      await saveReservationJob(job);reservationJobRef.current=job;setReservationJob(job);
      const reservation=await reserveWithRetry(job);
      if(reservation.status!=="reserved")throw new Error("The export reservation is not active. Please try again.");
      reservationRef.current=reservation.exportId;
      if(abortExport.current)throw new Error(cancelReason.current);
      renewTimer=setInterval(()=>{api(`/api/exports/${reservation.exportId}/renew`,{}).catch(()=>{});},45000);
      renderVideo=document.createElement("video");renderVideo.src=source;renderVideo.playsInline=true;renderVideo.preload="auto";renderVideo.muted=!audioContext;await ready(renderVideo);await seek(renderVideo,edit.inPoint);
      const renderCanvas=document.createElement("canvas");renderCanvas.width=frameWidth;renderCanvas.height=frameHeight;drawFrame(renderCanvas,renderVideo,edit);
      renderStream=renderCanvas.captureStream(30);
      let audioDestination:MediaStreamAudioDestinationNode|undefined;
      if(audioContext){const audioSource=audioContext.createMediaElementSource(renderVideo);audioDestination=audioContext.createMediaStreamDestination();sourceGain=audioContext.createGain();sourceGain.gain.value=envelopeGain(edit.sound.source,0,edit.outPoint-edit.inPoint);audioSource.connect(sourceGain);sourceGain.connect(audioDestination);audioDestination.stream.getAudioTracks().forEach(track=>renderStream!.addTrack(track));}
      const type=mimeType(!!audioContext),recorder=new MediaRecorder(renderStream,{mimeType:type,videoBitsPerSecond:5_000_000});
      const activeVideo=renderVideo;
      const blob=await new Promise<Blob>((resolve,reject)=>{
        const chunks:Blob[]=[];let size=0,frame=0,done=false,lastProgress=0,mediaStarted=false;const began=performance.now();
        let watchdog:ReturnType<typeof setInterval>|undefined;
        const finish=()=>{if(done)return;done=true;cancelAnimationFrame(frame);if(watchdog)clearInterval(watchdog);activeVideo.removeEventListener("waiting",stall);try{exportAudio.voice?.stop();}catch{}activeVideo.pause();if(recorder.state!=="inactive")recorder.stop();};
        const stall=()=>{if(!mediaStarted||done)return;cancelReason.current="Video decoding stalled. Export stopped to keep your audio in sync; your allowance was not used. Try again with other apps closed.";abortExport.current=true;finish();};activeVideo.addEventListener("waiting",stall);
        recorder.ondataavailable=(event)=>{if(event.data.size){chunks.push(event.data);size+=event.data.size;if(size>MAX_BYTES){abortExport.current=true;finish();}}};
        recorder.onerror=()=>{finish();reject(new Error("The browser encoder failed. Your export allowance has not been used."));};
        recorder.onstop=()=>{if(abortExport.current)reject(new Error(cancelReason.current));else resolve(new Blob(chunks,{type:recorder.mimeType}));};
        const tick=()=>{
          if(abortExport.current){finish();return;}
          if(performance.now()-began>(edit.outPoint-edit.inPoint+30)*1000){finish();reject(new Error("Export timed out. Keep this tab active while exporting."));return;}
          drawFrame(renderCanvas,activeVideo,edit);
          if(sourceGain&&audioContext)sourceGain.gain.setValueAtTime(envelopeGain(edit.sound.source,activeVideo.currentTime-edit.inPoint,edit.outPoint-edit.inPoint),audioContext.currentTime);
          if(mounted.current&&performance.now()-lastProgress>200){setProgress(clamp((activeVideo.currentTime-edit.inPoint)/(edit.outPoint-edit.inPoint),0,1));lastProgress=performance.now();}
          if(activeVideo.currentTime>=edit.outPoint-.018||activeVideo.ended){finish();return;}
          frame=requestAnimationFrame(tick);
        };
        watchdog=setInterval(()=>{if(abortExport.current){finish();return;}if(performance.now()-began>(edit.outPoint-edit.inPoint+30)*1000){cancelReason.current="Export timed out. Keep this tab active while rendering; your allowance has not been used.";abortExport.current=true;finish();}},200);
        recorder.start(500);activeVideo.play().then(()=>{if(done)return;mediaStarted=true;if(audioContext&&audioDestination&&selectedVoice()?.buffer&&edit.sound.voice)exportAudio.voice=scheduleVoice(audioContext,audioDestination,selectedVoice()!.buffer,edit.sound.voice,activeVideo.currentTime,edit.outPoint);frame=requestAnimationFrame(tick);}).catch(()=>{finish();reject(new Error("Playback was blocked. Click Export again to retry."));});
      });
      if(!blob.size)throw new Error("The browser returned an empty video. Your export allowance has not been used.");
      if(abortExport.current)throw new Error(cancelReason.current);
      const extension=blob.type.includes("mp4")?"mp4":"webm";
      const name=`${filename.replace(/[\\/:*?"<>|]/g,"-") || "Focus-demo"}-edited.${extension}`;
      committed=await confirmDownload({blob,exportId:reservation.exportId,name,accountId:account.account?.id,reservationKey:job.idempotencyKey,confirmed:false});
    }catch(error){if(mounted.current)setMessage(error instanceof Error?error.message:"Export failed. Please try again.");}
    finally{
      if(renewTimer)clearInterval(renewTimer);try{exportAudio.voice?.stop();}catch{}renderVideo?.pause();renderStream?.getTracks().forEach(track=>track.stop());if(audioContext)await audioContext.close().catch(()=>{});
      if(reservationRef.current&&!committed&&!pendingRef.current){try{await api(`/api/exports/${reservationRef.current}/release`,{});reservationRef.current=null;await removeReservationJob();reservationJobRef.current=null;setReservationJob(null);}catch{if(mounted.current)setMessage(previous=>`${previous} Your reservation could not be released yet; it will expire automatically.`);}}
      unlock?.();exportingRef.current=false;if(mounted.current)setPhase("editing");
    }
  }

  async function connectDesktop(){
    if(!window.focusDesktop||connectingAccount)return;setConnectingAccount(true);setMessage('');
    try{const result=await window.focusDesktop.startSignIn();setMessage(`Approve connection ${result.userCode} in your browser, then return here.`);}catch(error){setMessage(error instanceof Error?error.message:'Could not connect your account.');}finally{setConnectingAccount(false);}
  }
  const isRecording=phase==="recording"||phase==="paused",isEditing=phase==="editing"||phase==="exporting";
  return <div className="browser-studio"><header className="studio-header"><Brand/><span className="studio-beta">{desktop?"Desktop Studio":"Browser Studio"} <b>Preview</b></span><div className="studio-header-actions"><ThemeToggle/>{desktop?<button className="studio-account" disabled={connectingAccount} onClick={account?.authenticated?()=>{window.focusDesktop?.signOut().then(fetchAccount).catch(()=>setMessage("Could not sign out. Retry when online."));}:connectDesktop}>{connectingAccount?"Opening browser…":account?.authenticated?"Disconnect account":"Connect account"}<ArrowUpRight size={14}/></button>:<a href="/account" target="_blank" rel="noreferrer" className="studio-account">{account?.authenticated?"Your account":"Sign in"}<ArrowUpRight size={14}/></a>}</div></header><main className="studio-workspace"><div className="studio-title"><div><a href="/" className="studio-back"><ArrowLeft size={12}/> Focus Studio</a><h1>A little studio.<br/><span>{desktop?"On your desktop.":"Right in your browser."}</span></h1></div><p>Record or import. Trim. Find your focus.<br/>Everything you record stays on this device.</p></div>
    {pendingExport&&<div className="studio-recovery"><div><Check size={16}/><span>A rendered video is saved on this device.</span></div><div className="studio-recovery-actions"><button disabled={phase==="exporting"||isRecording||startingCapture||voiceBusy||voiceRecording} onClick={retryConfirmation}>Finish saved export <Download size={14}/></button><button className="discard" disabled={phase==="exporting"||isRecording||startingCapture||voiceBusy||voiceRecording} onClick={discardSavedRender}>Discard saved render</button></div></div>}
    {reservationJob&&!pendingExport&&phase!=="exporting"&&<div className="studio-recovery"><div><Info size={16}/><span>An interrupted export may hold your allowance.</span></div><button onClick={clearInterruptedReservation}>Recover reservation <RotateCcw size={14}/></button></div>}
    {message&&<div className="studio-message" role="status"><Info size={16}/><p>{message}{!account?.authenticated&&source&&<a href="/account" target="_blank" rel="noreferrer">Open account <ArrowUpRight size={12}/></a>}</p><button aria-label="Dismiss message" onClick={()=>setMessage("")}><X size={16}/></button></div>}
    <div className="studio-grid"><section className="studio-canvas-panel" aria-label="Video preview"><div className="studio-panel-bar"><span><span className={isRecording?"studio-record-dot":"studio-idle-dot"}/>{isRecording?phase==="paused"?"Recording paused":"Recording your screen":source?filename:"Your next story"}</span><span>{isRecording?time(elapsed):"720p export"}</span></div><div className={`studio-preview${source&&!isRecording?" has-source":""}`}>
      <video ref={videoRef} src={source||undefined} playsInline preload="auto" className="studio-source-video" onLoadedMetadata={loadedMetadata} onTimeUpdate={()=>{const video=videoRef.current;if(!video)return;setPosition(video.currentTime);if(video.currentTime>=editRef.current.outPoint&&!video.paused){video.pause();}}} onPlay={()=>setPlaying(true)} onPause={()=>setPlaying(false)} onError={()=>{if(source)setMessage("Your browser cannot play this file. Try a compatible MP4 or WebM.");}}/>
      <canvas ref={canvasRef} width={frameWidth} height={frameHeight} onClick={choosePoint} onKeyDown={nudgeFocus} tabIndex={source&&phase==="editing"?0:-1} aria-label="Video preview and focus selector. Click, or use the arrow keys, to choose a focus point."/>
      {(!source||isRecording)&&<div className="studio-empty"><div className={isRecording?"studio-empty-icon recording":"studio-empty-icon"}>{isRecording?<Circle size={36}/>:<Focus size={48} strokeWidth={1.2}/>}</div><h2>{isRecording?phase==="paused"?"Take your time.":"You’re on.":"Start with something worth showing."}</h2><p>{isRecording?"Return to your product window. Stop here when you’re done.":"Choose a screen to record, or bring a video you already have."}</p>{isRecording?<div className="studio-recording-actions"><button onClick={pauseRecording}>{phase==="paused"?<Play size={15}/>:<Pause size={15}/>} {phase==="paused"?"Resume":"Pause"}</button><button onClick={stopRecording} className="stop"><Square size={13} fill="currentColor"/> Stop recording</button></div>:<div className="studio-start-actions"><button className="button button-dark" onClick={startRecording} disabled={!support.record||startingCapture||loadingSample}><Monitor size={17}/> {startingCapture?"Choose your screen…":"Record screen"}</button><button className="button button-outline" disabled={startingCapture||loadingSample} onClick={()=>fileRef.current?.click()}><Upload size={16}/> Import video</button></div>}{!isRecording&&<button className="studio-sample-button" onClick={loadSample} disabled={loadingSample||startingCapture}>{loadingSample?"Loading sample…":"Just exploring? Try a sample"}<ArrowUpRight size={12}/></button>}{isRecording&&<small>{capturedAudio?"Shared audio is being recorded.":"No audio was shared by your browser."}</small>}{!isRecording&&!support.record&&<small>Screen recording is not available in this browser. You can still import a video.</small>}</div>}
      {phase==="exporting"&&<div className="studio-export-overlay"><div className="studio-export-spinner"/><h3>{pendingExport?"Confirming your export.":"Putting your story together."}</h3><p>{pendingExport?"Your video is saved locally.":`${Math.round(progress*100)}% · Keep this tab active`}</p><progress value={progress} max={1}/>{!pendingExport&&<button onClick={()=>{abortExport.current=true;}}>Cancel export</button>}</div>}
    </div>{isEditing&&<div className="studio-player"><button aria-label={playing?"Pause video":"Play video"} disabled={phase==="exporting"||voiceBusy||voiceRecording||!duration} onClick={togglePlay}>{playing?<Pause size={16}/>:<Play size={16} fill="currentColor"/>}</button><span>{time(position)}</span><input aria-label="Playhead position" type="range" min={0} max={duration||1} step={.0333} value={Math.min(position,duration)} disabled={phase==="exporting"||voiceBusy||voiceRecording} onChange={e=>setPositionTo(Number(e.target.value))}/><span>{time(duration)}</span><span className="studio-key">Space</span></div>}
      {!isRecording&&<div className="studio-local-note"><span><Check size={12}/> Local processing. No video uploads.</span><span>Beta: 2 minutes · 250 MB max</span></div>}
    </section>
    <aside className="studio-inspector"><div className="studio-inspector-title"><span>Your edit</span><div><button onClick={undoEdit} disabled={!undo.length||phase!=="editing"||voiceBusy||voiceRecording} aria-label="Undo edit"><RotateCcw size={15}/></button><button onClick={redoEdit} disabled={!redo.length||phase!=="editing"||voiceBusy||voiceRecording} aria-label="Redo edit"><RotateCcw size={15} className="redo"/></button></div></div><fieldset disabled={!isEditing||phase==="exporting"||voiceBusy||voiceRecording||!duration} className="studio-fields"><legend className="sr-only">Edit settings</legend><div className="studio-control-section"><h3><Scissors size={14}/> Keep the good part</h3><div className="studio-time-fields"><label>In<input type="number" min={0} max={Math.max(0,edit.outPoint-.1)} step={.1} value={edit.inPoint.toFixed(1)} onChange={e=>updateEdit({...edit,inPoint:clamp(Number(e.target.value)||0,0,Math.max(0,edit.outPoint-.1))})}/></label><label>Out<input type="number" min={edit.inPoint+.1} max={duration} step={.1} value={edit.outPoint.toFixed(1)} onChange={e=>updateEdit({...edit,outPoint:clamp(Number(e.target.value)||0,edit.inPoint+.1,duration)})}/></label></div><label className="studio-range-label">Start<input aria-label="Trim start" type="range" min={0} max={duration||1} step={.0333} value={edit.inPoint} onPointerDown={beginRange} onPointerUp={finishRange} onBlur={finishRange} onKeyDown={beginRange} onKeyUp={finishRange} onChange={e=>{setEdit({...edit,inPoint:clamp(Number(e.target.value),0,Math.max(0,edit.outPoint-.1))});setPositionTo(Number(e.target.value));}}/></label><label className="studio-range-label">End<input aria-label="Trim end" type="range" min={0} max={duration||1} step={.0333} value={edit.outPoint} onPointerDown={beginRange} onPointerUp={finishRange} onBlur={finishRange} onKeyDown={beginRange} onKeyUp={finishRange} onChange={e=>{setEdit({...edit,outPoint:clamp(Number(e.target.value),edit.inPoint+.1,duration)});setPositionTo(Number(e.target.value));}}/></label><p className="studio-selection-duration">Selected <b>{time(edit.outPoint-edit.inPoint)}</b></p></div>
      <div className="studio-control-section"><h3><Focus size={14}/> Find your focus</h3><div className="studio-effect-options">{([{id:"none",label:"Original",Icon:Maximize},{id:"zoom",label:"Zoom",Icon:Focus},{id:"spotlight",label:"Spotlight",Icon:Scan}] as const).map(({id,label,Icon})=><button key={id} aria-pressed={edit.effect===id} className={edit.effect===id?"selected":""} onClick={()=>{updateEdit({...edit,effect:id});if(position<=edit.inPoint+.1||position>=edit.outPoint-.1)setPositionTo((edit.inPoint+edit.outPoint)/2);}}><Icon size={18}/><span>{label}</span></button>)}</div><p className="studio-control-hint"><MousePointer2 size={12}/> Click the preview to focus. Arrow keys also work.</p><p className="studio-focus-coordinates">{Math.round(edit.point.x*100)}% horizontal · {Math.round(edit.point.y*100)}% vertical</p></div>
    </fieldset><div className="studio-control-section studio-capture-settings"><h3><Mic size={14}/> Recording inputs</h3><label className="studio-audio-toggle"><span>System / shared audio</span><input type="checkbox" checked={includeAudio} disabled={isRecording||startingCapture||voiceBusy||voiceRecording||phase==='exporting'||desktop?.systemAudio==='unavailable'} onChange={e=>setIncludeAudio(e.target.checked)}/></label><label className="studio-audio-toggle"><span>Microphone</span><input type="checkbox" checked={includeMic} disabled={isRecording||startingCapture||voiceBusy||voiceRecording||phase==='exporting'} onChange={e=>setIncludeMic(e.target.checked)}/></label><details><summary>Microphone settings</summary><label>Input<select aria-label="Microphone input" value={micDevice} disabled={isRecording||voiceBusy||voiceRecording||startingCapture} onChange={e=>setMicDevice(e.target.value)}><option value="">System default</option>{micDevices.filter(d=>d.deviceId&&d.deviceId!=='default').map((device,i)=><option key={device.deviceId} value={device.deviceId}>{device.label||`Microphone ${i+1}`}</option>)}</select></label><label className="studio-audio-toggle"><span>Voice clarity</span><input type="checkbox" checked={cleanVoice} disabled={isRecording||voiceBusy||voiceRecording||startingCapture} onChange={e=>setCleanVoice(e.target.checked)}/></label></details><p className="studio-control-hint">{desktop?.systemAudio==='unavailable'?'Linux: use a microphone or import audio. System audio is unavailable in this preview.':desktop?.systemAudio==='loopback'?'System audio includes all computer sounds.':'Shared audio depends on the browser and selected source.'}</p></div><div className="studio-export-section"><button className="button button-dark" disabled={!duration||phase!=="editing"||startingCapture||voiceBusy||voiceRecording||!support.export} onClick={exportVideo}><Download size={16}/> {pendingExport?"Retry export confirmation":"Export video"}</button><small>{account?.authenticated?account.entitlement?.canExport?account.entitlement.freeExportsRemaining>0?"Your first successful export is free.":"Your subscription covers this export.":"Check your account for export access.":"Sign in to claim one free successful export."}</small>{lastDownload&&<div><a className="studio-download-again" href={lastDownload.url} download={lastDownload.name}><Check size={13}/> Download your last export again</a><button className="studio-clear-saved" onClick={()=>{clearSavedExport().catch(()=>setMessage("The saved export could not be cleared. Please try again."));}}>Remove saved copy from browser</button></div>}{!support.export&&<p className="studio-control-hint">Safe local export is unavailable. Try a current desktop browser.</p>}</div></aside></div>
    {source&&!isRecording&&<AudioPanel onBegin={beginRange} onEnd={finishRange} onDraft={sound=>{const next={...editRef.current,sound};editRef.current=next;setEdit(next);}} sound={edit.sound} onChange={sound=>updateEdit({...edit,sound})} disabled={phase!=='editing'||startingCapture||voiceBusy||voiceRecording} hasVideo={!!duration} voiceName={voiceAssets.current.get(edit.sound.voice?.assetId??'')?.name??''} voiceDuration={voiceAssets.current.get(edit.sound.voice?.assetId??'')?.buffer.duration??0} peaks={voiceAssets.current.get(edit.sound.voice?.assetId??'')?.peaks??[]} recording={voiceRecording} busy={voiceBusy} level={voiceLevel} onImport={()=>voiceInput.current?.click()} onRecord={()=>void recordVoice()} onStop={()=>{if(voiceRecorder.current?.state!=='inactive')voiceRecorder.current?.stop();}} duration={duration}/>}
    {source&&!isRecording&&phase!=="exporting"&&!voiceBusy&&!voiceRecording&&<div className="studio-replace"><button onClick={startRecording} disabled={!support.record||startingCapture||loadingSample}><Monitor size={14}/> Record another take</button><button onClick={()=>fileRef.current?.click()}><Upload size={14}/> Import another video</button><span>Importing replaces this temporary edit. Download your result first.</span></div>}
    <input ref={voiceInput} type="file" accept="audio/*" hidden onChange={e=>{void importVoice(e.target.files?.[0]);e.target.value="";}}/>
    <input ref={fileRef} type="file" accept="video/*" hidden onChange={e=>{importFile(e.target.files?.[0]);e.target.value="";}}/>
    <footer className="studio-footer"><p><Info size={14}/> Browser Studio is a lightweight beta. Exports use the video format supported by your browser; rendering happens in real time.</p><a href="/help#installation">Need the full editor? Get the Mac app <ArrowUpRight size={13}/></a></footer>
  </main></div>;
}
