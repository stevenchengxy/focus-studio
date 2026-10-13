"use client";

import { useEffect, useRef, useState, type RefObject } from "react";
import { ArrowUpRight, Check, ChevronRight, Circle, Focus, Layers3, Maximize2, MousePointer2, Pause, Play, RotateCcw, Scan, Sparkles } from "lucide-react";

type Scene = "perspective" | "zoom" | "spotlight" | "lift";
const scenes = [
  { id: "perspective" as const, label: "Perspective", Icon: Layers3 },
  { id: "zoom" as const, label: "Smooth zoom", Icon: Focus },
  { id: "spotlight" as const, label: "Spotlight", Icon: Scan },
  { id: "lift" as const, label: "Detail lift", Icon: Maximize2 },
];
const duration = 12_000;
const glide = "cubic-bezier(.22,.74,.16,1)";

function cameraFrames(scene: Scene): Keyframe[] {
  const overview = "translate3d(0,0,0) rotateX(7deg) rotateY(-11deg) rotateZ(-2deg) scale(.90)";
  const focus: Record<Scene, string> = {
    perspective: "translate3d(-2%,1%,40px) rotateX(10deg) rotateY(16deg) rotateZ(2deg) scale(.92)",
    zoom: "translate3d(-5%,-8%,75px) rotateX(0deg) rotateY(0deg) rotateZ(0deg) scale(1.27)",
    spotlight: "translate3d(0,0,0) rotateX(0deg) rotateY(0deg) rotateZ(0deg) scale(.98)",
    lift: "translate3d(0,3%,-25px) rotateX(9deg) rotateY(-13deg) rotateZ(-3deg) scale(.89)",
  };
  return [
    { transform: overview, offset: 0 },
    { transform: overview, offset: .12, easing: glide },
    { transform: focus[scene], offset: .34 },
    { transform: focus[scene], offset: .65, easing: glide },
    { transform: overview, offset: .88 },
    { transform: overview, offset: 1 },
  ];
}

/** Every layer shares one timeline; only transforms and opacity run each frame. */
function useSceneTimeline(stage: RefObject<HTMLDivElement | null>, scene: Scene, enabled: boolean) {
  const animations = useRef<Animation[]>([]);
  const visible = useRef(false);
  const enabledRef = useRef(enabled);
  enabledRef.current = enabled;
  const syncRef = useRef(() => {});

  useEffect(() => {
    const root = stage.current;
    if (!root) return;
    const sequence: Animation[] = [];
    const add = (selector: string, frames: Keyframe[], options: KeyframeAnimationOptions = {}) => {
      root.querySelectorAll<HTMLElement>(selector).forEach((element) => {
        const animation = element.animate(frames, { duration, iterations: Infinity, fill: "both", ...options });
        animation.pause();
        animation.currentTime = enabledRef.current ? 0 : duration * .46;
        sequence.push(animation);
      });
    };
    add(".fs-scene-frame", cameraFrames(scene));
    add(".fs-scene-backplate", [
      { transform: "translate3d(-1%,3%,-65px) rotateX(7deg) rotateY(-11deg) rotateZ(-2deg) scale(.9)", opacity: .45 },
      { transform: "translate3d(3%,8%,-65px) rotateX(10deg) rotateY(16deg) rotateZ(2deg) scale(.92)", opacity: scene === "perspective" ? .9 : .2, offset: .46 },
      { transform: "translate3d(-1%,3%,-65px) rotateX(7deg) rotateY(-11deg) rotateZ(-2deg) scale(.9)", opacity: .45 },
    ], { easing: "ease-in-out" });
    add(".fs-scene-pointer", [
      { transform: "translate3d(55px,35px,160px)", opacity: 0, offset: 0 },
      { transform: "translate3d(55px,35px,160px)", opacity: 1, offset: .12, easing: glide },
      { transform: "translate3d(0,0,160px)", opacity: 1, offset: .28 },
      { transform: "translate3d(0,0,160px) scale(.85)", opacity: 1, offset: .31 },
      { transform: "translate3d(0,0,160px)", opacity: 1, offset: .34 },
      { transform: "translate3d(0,0,160px)", opacity: 1, offset: .65 },
      { transform: "translate3d(60px,28px,160px)", opacity: 0, offset: .83 },
      { transform: "translate3d(60px,28px,160px)", opacity: 0 },
    ]);
    add(".fs-click-ring", [
      { transform: "scale(.45)", opacity: 0, offset: 0 },
      { transform: "scale(.45)", opacity: 0, offset: .28 },
      { transform: "scale(.6)", opacity: .7, offset: .30 },
      { transform: "scale(2)", opacity: 0, offset: .39 },
      { transform: "scale(2)", opacity: 0 },
    ]);
    const emphasis = scene === "spotlight" || scene === "lift";
    const detailPose = scene === "lift"
      ? "translate3d(0,-18%,150px) rotateX(5deg) rotateY(-12deg) rotateZ(-3deg) scale(1.09)"
      : "translate3d(0,0,90px) scale(1.05)";
    add(".fs-detail-panel", [
      { transform: "translate3d(0,0,0) scale(.84)", opacity: 0, offset: 0 },
      { transform: "translate3d(0,0,0) scale(.84)", opacity: 0, offset: .24, easing: glide },
      { transform: detailPose, opacity: emphasis ? 1 : 0, offset: .40 },
      { transform: detailPose, opacity: emphasis ? 1 : 0, offset: .65, easing: glide },
      { transform: "translate3d(0,0,0) scale(.84)", opacity: 0, offset: .87 },
      { transform: "translate3d(0,0,0) scale(.84)", opacity: 0 },
    ]);
    add(".fs-scene-shade", [
      { opacity: 0 }, { opacity: 0, offset: .24 },
      { opacity: scene === "spotlight" ? .74 : scene === "lift" ? .42 : 0, offset: .4 },
      { opacity: scene === "spotlight" ? .74 : scene === "lift" ? .42 : 0, offset: .65 },
      { opacity: 0, offset: .87 }, { opacity: 0 },
    ]);
    add(".fs-scene-progress i", [{ transform: "scaleX(0)" }, { transform: "scaleX(1)" }]);
    add(".fs-scene-phases span:nth-child(1)", [{ opacity: 1 }, { opacity: 1, offset: .22 }, { opacity: .3, offset: .3 }, { opacity: .3 }]);
    add(".fs-scene-phases span:nth-child(2)", [{ opacity: .3 }, { opacity: .3, offset: .22 }, { opacity: 1, offset: .3 }, { opacity: 1, offset: .67 }, { opacity: .3, offset: .76 }, { opacity: .3 }]);
    add(".fs-scene-phases span:nth-child(3)", [{ opacity: .3 }, { opacity: .3, offset: .67 }, { opacity: 1, offset: .76 }, { opacity: 1 }]);
    animations.current = sequence;

    const sync = () => {
      const running = enabledRef.current && visible.current && !document.hidden;
      root.dataset.running = String(running);
      sequence.forEach((animation) => running ? animation.play() : animation.pause());
    };
    syncRef.current = sync;
    const observer = new IntersectionObserver(([entry]) => {
      visible.current = entry.isIntersecting && entry.intersectionRatio > .08;
      sync();
    }, { threshold: [0, .08, .2] });
    observer.observe(root);
    document.addEventListener("visibilitychange", sync);
    sync();
    return () => {
      observer.disconnect();
      document.removeEventListener("visibilitychange", sync);
      sequence.forEach((animation) => animation.cancel());
      animations.current = [];
      syncRef.current = () => {};
    };
  }, [scene, stage]);

  useEffect(() => { syncRef.current(); }, [enabled]);
  return () => {
    animations.current.forEach((animation) => { animation.currentTime = 0; });
    syncRef.current();
  };
}

function ProgressCard() {
  return <><div className="fs-card-top"><span>Ready for the world.</span><span className="fs-card-status"><i/> On track</span></div><div className="fs-card-value">75<span>%</span><Sparkles size={19}/></div><div className="fs-card-bars">{[30, 42, 35, 57, 49, 65, 73, 64, 84, 96, 89, 100].map((height, index) => <i key={index} style={{ height: `${height}%` }}/>)}</div><div className="fs-card-bottom"><span>Launch readiness</span><span>24 / 32 tasks</span></div></>;
}

export function ProductMotion({ motion, onMotionChange }: { motion: boolean; onMotionChange: (motion: boolean) => void }) {
  const [scene, setScene] = useState<Scene>("perspective");
  const stageRef = useRef<HTMLDivElement>(null);
  const cameraRef = useRef<HTMLDivElement>(null);
  const pointerFrame = useRef(0);
  const pointerBounds = useRef<DOMRect | null>(null);
  const replay = useSceneTimeline(stageRef, scene, motion);
  useEffect(() => () => cancelAnimationFrame(pointerFrame.current), []);
  useEffect(() => {
    if (!motion) {
      cancelAnimationFrame(pointerFrame.current);
      if (cameraRef.current) cameraRef.current.style.transform = "";
    }
  }, [motion]);

  return <div className="fs-motion-showcase" data-scene={scene}>
    <div className="fs-motion-top"><span><Focus size={15}/> A little perspective.</span><span>INTERACTIVE ILLUSTRATION</span><div><button onClick={() => { replay(); onMotionChange(true); }} aria-label="Replay effect animation" title="Replay"><RotateCcw size={14}/></button><button onClick={() => onMotionChange(!motion)} aria-label={motion ? "Pause animation" : "Play animation"} aria-pressed={!motion} title={motion ? "Pause animation" : "Play animation"}>{motion ? <Pause size={14}/> : <Play size={14}/>}</button></div></div>
    <div className="fs-scene" ref={stageRef}
      onPointerEnter={(event) => { if (event.pointerType === "mouse") pointerBounds.current = event.currentTarget.getBoundingClientRect(); }}
      onPointerMove={(event) => {
        if (!motion || event.pointerType !== "mouse" || !pointerBounds.current || stageRef.current?.dataset.running !== "true") return;
        const bounds = pointerBounds.current;
        const x = Math.max(-1, Math.min(1, (event.clientX - bounds.left) / bounds.width * 2 - 1));
        const y = Math.max(-1, Math.min(1, (event.clientY - bounds.top) / bounds.height * 2 - 1));
        cancelAnimationFrame(pointerFrame.current);
        pointerFrame.current = requestAnimationFrame(() => {
          if (cameraRef.current) cameraRef.current.style.transform = `rotateX(${-y * 2}deg) rotateY(${x * 3}deg)`;
        });
      }}
      onPointerLeave={() => { cancelAnimationFrame(pointerFrame.current); pointerBounds.current = null; if (cameraRef.current) cameraRef.current.style.transform = ""; }}>
      <div className="fs-scene-light fs-scene-light-violet"/><div className="fs-scene-light fs-scene-light-mint"/><div className="fs-scene-grid"/>
      <div className="fs-scene-camera" ref={cameraRef} role="img" aria-label={`${scenes.find((item) => item.id === scene)?.label} effect applied to an illustrative product dashboard`}>
        <div className="fs-scene-backplate" aria-hidden="true"/>
        <div className="fs-scene-frame" aria-hidden="true">
          <div className="fs-window-chrome"><div><i/><i/><i/></div><span>aster / launch day</span><Maximize2 size={10}/></div>
          <div className="fs-window-content"><aside className="fs-product-side"><div className="fs-product-brand"><span>✳</span> aster</div><span className="fs-side-caption">WORKSPACE</span><span className="fs-side-active"><Layers3/> Overview</span><span><Circle/> Projects</span><span><Check/> Your tasks</span><span className="fs-side-bottom"><i>J</i> Jamie’s workspace</span></aside><div className="fs-product-main"><div className="fs-product-breadcrumb">Workspace <ChevronRight size={10}/> Launch day</div><div className="fs-product-heading"><div><span>GOOD THINGS TAKE SHAPE.</span><h3>Your next<br/>big thing.</h3></div><div className="fs-product-avatars"><i>J</i><i>A</i><i>M</i></div></div><div className="fs-product-tabs"><b>Overview</b><span>Board</span><span>Files</span><i>Invite <ArrowUpRight size={10}/></i></div><div className="fs-product-cards"><div className="fs-product-progress"><ProgressCard/></div><div className="fs-product-note"><Sparkles size={20}/><span>A clear story.<br/>A confident<br/>launch.</span><i>Make it happen <ArrowUpRight size={10}/></i></div></div><div className="fs-product-task"><span><Check size={11}/></span><b>Bring the details into focus</b><i>Done</i></div></div></div>
        </div>
        <div className="fs-scene-shade" aria-hidden="true"/>
        <div className="fs-detail-panel" aria-hidden="true"><ProgressCard/><span className="fs-detail-corner corner-tl"/><span className="fs-detail-corner corner-tr"/><span className="fs-detail-corner corner-bl"/><span className="fs-detail-corner corner-br"/></div>
        <div className="fs-scene-pointer" aria-hidden="true"><i className="fs-click-ring"/><MousePointer2 fill="white" stroke="#30253e" size={31}/><span>Your moment.</span></div>
      </div>
      <div className="fs-scene-bottom" aria-hidden="true"><div className="fs-scene-phases"><span>01 &nbsp; Frame</span><span>02 &nbsp; Focus</span><span>03 &nbsp; Flow</span></div><div className="fs-scene-progress"><i/></div><span>12s loop</span></div>
    </div>
    <div className="fs-motion-controls" role="group" aria-label="Choose a demo effect">{scenes.map(({ id, label, Icon }) => <button key={id} className={scene === id ? "selected" : ""} aria-pressed={scene === id} onClick={() => setScene(id)}><Icon size={15}/>{label}</button>)}</div>
  </div>;
}

/** Reveals and small feature loops are visibility driven, never scroll/RAF state. */
export function useMarketingMotion(scope: RefObject<HTMLDivElement | null>, enabled: boolean) {
  useEffect(() => {
    const root = scope.current;
    if (!root) return;
    const elements = Array.from(root.querySelectorAll<HTMLElement>("[data-reveal], [data-motion-section]"));
    const visibility = new Map<HTMLElement, boolean>();
    const sync = () => elements.forEach((element) => {
      element.style.setProperty("--scene-play-state", enabled && visibility.get(element) && !document.hidden ? "running" : "paused");
    });
    root.dataset.motionReady = String(enabled);
    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        const element = entry.target as HTMLElement;
        visibility.set(element, entry.isIntersecting);
        if (entry.isIntersecting) element.dataset.revealed = "true";
      });
      sync();
    }, { threshold: .12, rootMargin: "0px 0px -25px 0px" });
    elements.forEach((element) => observer.observe(element));
    document.addEventListener("visibilitychange", sync);
    sync();
    return () => { observer.disconnect(); document.removeEventListener("visibilitychange", sync); elements.forEach((element) => element.style.setProperty("--scene-play-state", "paused")); };
  }, [scope, enabled]);
}
