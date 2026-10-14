"use client";

import { useEffect, useRef, useState } from "react";
import { Pause, Play } from "lucide-react";
import styles from "./product-video.module.css";

/** Native renderer output, presented level. Decode only while on screen. */
export function ProductVideo({ motion, compact = false }: { motion: boolean; compact?: boolean }) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [paused, setPaused] = useState(false);
  const [playing, setPlaying] = useState(false);
  const [requestedPlay, setRequestedPlay] = useState(false);

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    let visible = false;
    const sync = () => {
      if (visible && !document.hidden && !paused && (motion || requestedPlay)) {
        void video.play().catch(() => setPlaying(false));
      } else video.pause();
    };
    const observer = new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting;
      sync();
    }, { threshold: 0.05 });
    observer.observe(video);
    document.addEventListener("visibilitychange", sync);
    return () => {
      observer.disconnect();
      document.removeEventListener("visibilitychange", sync);
      video.pause();
    };
  }, [motion, paused, requestedPlay]);

  const toggle = () => {
    if (playing) setPaused(true);
    else { setPaused(false); setRequestedPlay(true); }
  };

  return <div className={`${styles.stage}${compact ? ` ${styles.compact}` : ""}`} data-reveal={compact ? undefined : true}>
    <video ref={videoRef} src="/media/focus-studio-demo-flat.mp4"
      poster="/media/focus-studio-demo-flat.jpg" muted loop playsInline preload="metadata"
      aria-label="Focus Studio exported effects on a sample dashboard"
      onPlay={() => setPlaying(true)} onPause={() => setPlaying(false)}>
      <a href="/media/focus-studio-demo-flat.mp4">Watch the Focus Studio demo</a>
    </video>
    <button className={styles.playback} onClick={toggle} aria-label={playing ? "Pause demo" : "Play demo"}>
      {playing ? <Pause size={16}/> : <Play size={16}/>}
    </button>
  </div>;
}
