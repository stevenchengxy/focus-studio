"use client";

import { useEffect, useRef, useState } from "react";
import { ArrowUpRight, Play, X } from "lucide-react";
import { useLocale } from "@/components/locale/locale-provider";
import styles from "./tutorial-videos.module.css";

type TutorialId = "edit" | "codex" | "community";
type CaptionTrack = { src: string; language: "en" | "zh"; label: string };
const tutorials = [
  { id: "edit", title: ["Edit a demo", "剪辑一支 Demo"] },
  { id: "codex", title: ["Connect & check Codex", "连接与检查 Codex"] },
  { id: "community", title: ["Community & private drafts", "社区与私密草稿"] },
] as const;
const defaultCaptions: Record<TutorialId, CaptionTrack[]> = {
  edit: [
    { src: "/media/tutorial-edit.en.vtt", language: "en", label: "English" },
    { src: "/media/tutorial-edit.zh.vtt", language: "zh", label: "简体中文" },
  ],
  codex: [
    { src: "/media/tutorial-codex.en.vtt", language: "en", label: "English" },
    { src: "/media/tutorial-codex.zh.vtt", language: "zh", label: "简体中文" },
  ],
  community: [
    { src: "/media/tutorial-community.en.vtt", language: "en", label: "English" },
    { src: "/media/tutorial-community.zh.vtt", language: "zh", label: "简体中文" },
  ],
};

/** Only mount a video after a visitor chooses a tutorial. */
export function TutorialVideos({ captions = defaultCaptions }: { captions?: Partial<Record<TutorialId, CaptionTrack[]>> }) {
  const { t, locale } = useLocale();
  const [active, setActive] = useState<(typeof tutorials)[number] | null>(null);
  const [failed, setFailed] = useState(false);
  const dialogRef = useRef<HTMLDialogElement>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  const triggerRef = useRef<HTMLButtonElement | null>(null);

  useEffect(() => {
    const dialog = dialogRef.current;
    const video = videoRef.current;
    if (!dialog || !active || !video) return;

    const previousVideos = Array.from(document.querySelectorAll("video"))
      .filter((item) => item !== video && !item.paused && !item.ended);
    previousVideos.forEach((item) => item.pause());
    const pauseBackground = (event: Event) => {
      if (event.target instanceof HTMLVideoElement && event.target !== video) event.target.pause();
    };
    document.addEventListener("play", pauseBackground, true);
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    dialog.showModal();
    void video.play().catch(() => { /* Native controls remain available if playback is blocked. */ });

    const pauseWhenHidden = () => { if (document.hidden) video.pause(); };
    document.addEventListener("visibilitychange", pauseWhenHidden);
    return () => {
      document.removeEventListener("visibilitychange", pauseWhenHidden);
      document.removeEventListener("play", pauseBackground, true);
      video.pause();
      dialog.close();
      document.body.style.overflow = previousOverflow;
      triggerRef.current?.focus({ preventScroll: true });
      if (!document.hidden) previousVideos.filter((item) => item.isConnected).forEach((item) => {
        void item.play().catch(() => {});
      });
    };
  }, [active]);

  return <section className={`section-wrap ${styles.section}`} id="tutorials" aria-labelledby="tutorials-title">
    <div className={styles.heading} data-reveal>
      <h2 id="tutorials-title">{t("See how it works.", "看一遍，就会用。")}</h2>
      <a href="/help">{t("Getting started", "快速上手")} <ArrowUpRight size={16} aria-hidden="true"/></a>
    </div>
    <div className={styles.grid}>
      {tutorials.map((tutorial, index) => <button
        type="button"
        key={tutorial.id}
        className={styles.card}
        data-reveal
        aria-label={`${t("Watch:", "观看：")} ${t(tutorial.title[0], tutorial.title[1])}`}
        aria-haspopup="dialog"
        aria-controls="tutorial-player"
        onClick={(event) => {
          triggerRef.current = event.currentTarget;
          setFailed(false);
          setActive(tutorial);
        }}
      >
        <span className={styles.poster}>
          <img src={`/media/tutorial-${tutorial.id}.jpg`} alt="" width="960" height="600" loading="lazy" decoding="async"/>
          <span className={styles.play}><Play size={20} fill="currentColor" aria-hidden="true"/></span>
        </span>
        <span className={styles.cardFooter}><span className={styles.number}>{String(index + 1).padStart(2, "0")}</span><span>{t(tutorial.title[0], tutorial.title[1])}</span><ArrowUpRight size={19} aria-hidden="true"/></span>
      </button>)}
    </div>
    <dialog id="tutorial-player" ref={dialogRef} className={styles.dialog} aria-labelledby="tutorial-video-title"
      onCancel={() => setActive(null)}
      onClick={(event) => { if (event.target === event.currentTarget) setActive(null); }}>
      {active && <div className={styles.player}>
        <header className={styles.playerHeader}>
          <h3 id="tutorial-video-title">{t(active.title[0], active.title[1])}</h3>
          <button type="button" autoFocus onClick={() => setActive(null)} aria-label={t("Close tutorial", "关闭教程")}><X size={21}/></button>
        </header>
        <video key={active.id} ref={videoRef} src={`/media/tutorial-${active.id}.mp4`} poster={`/media/tutorial-${active.id}.jpg`}
          controls playsInline preload="none" onError={() => setFailed(true)} aria-label={t(active.title[0], active.title[1])}>
          {/* Chinese instructions are already rendered in the recording. Avoid showing them twice. */}
          {(captions[active.id] ?? []).map((track) => <track key={track.language} kind="captions" src={track.src} srcLang={track.language} label={track.label} default={locale === "en" && track.language === "en"}/>)}
          {t("Your browser does not support this video.", "你的浏览器不支持此视频。")}
          <a href={`/media/tutorial-${active.id}.mp4`}>{t("Open video", "直接打开视频")}</a>
        </video>
        {failed && <p className={styles.error} role="status">{t("The video couldn’t load.", "视频暂时无法加载。")}
          <a href={`/media/tutorial-${active.id}.mp4`}>{t("Open video", "直接打开视频")} <ArrowUpRight size={14}/></a>
        </p>}
      </div>}
    </dialog>
  </section>;
}
