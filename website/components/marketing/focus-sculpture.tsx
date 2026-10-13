"use client";

import { useId, type CSSProperties } from "react";
import styles from "./focus-sculpture.module.css";

interface FocusSculptureProps {
  variant?: "hero" | "closing";
  className?: string;
  /** Overrides the responsive default; e.g. "320px" or "clamp(180px, 24vw, 360px)". */
  size?: CSSProperties["width"];
  style?: CSSProperties;
}

const aperture = "M26 2H74C90 2 98 10 98 26V74C98 90 90 98 74 98H26C10 98 2 90 2 74V26C2 10 10 2 26 2ZM31 22C25 22 22 25 22 31V69C22 75 25 78 31 78H69C75 78 78 75 78 69V31C78 25 75 22 69 22H31Z";
const contour = "M26 2H74C90 2 98 10 98 26V74C98 90 90 98 74 98H26C10 98 2 90 2 74V26C2 10 10 2 26 2Z";

/** Decorative only. The surrounding section owns visibility and motion controls. */
export function FocusSculpture({ variant = "hero", className = "", size, style }: FocusSculptureProps) {
  const id = `focus-aperture-${useId().replace(/[^a-zA-Z0-9_-]/g, "")}`;
  return (
    <div
      className={`${styles.sculpture} ${styles[variant]} ${className}`}
      style={{ "--sculpture-size": size, ...style } as CSSProperties}
      aria-hidden="true"
    >
      <div className={styles.ground} />
      <div className={styles.stage}>
        <div className={styles.orbit}>
          <svg viewBox="0 0 100 100" focusable="false">
            <path d={contour} />
            <path className={styles.orbitAccent} d="M2 36V26C2 10 10 2 26 2H43" />
          </svg>
          <i className={styles.orbitMarker} />
        </div>
        <div className={styles.object}>
          {Array.from({ length: 12 }, (_, index) => (
            <div
              key={index}
              className={styles.slice}
              style={{ "--slice": index } as CSSProperties}
            />
          ))}
          <div className={styles.backEdge} />
          <svg className={styles.face} viewBox="0 0 100 100" focusable="false">
            <defs>
              <linearGradient id={`${id}-porcelain`} x1="7%" y1="3%" x2="91%" y2="100%">
                <stop stopColor="#fffefb" />
                <stop offset=".24" stopColor="#e9dcff" />
                <stop offset=".49" stopColor="#d2b8f4" />
                <stop offset=".72" stopColor="#b496db" />
                <stop offset="1" stopColor="#e4d6f5" />
              </linearGradient>
              <linearGradient id={`${id}-rim`} x1="0" y1="0" x2="1" y2="1">
                <stop stopColor="#fffefb" stopOpacity=".95" />
                <stop offset=".46" stopColor="#fffefb" stopOpacity=".45" />
                <stop offset=".7" stopColor="#74518e" stopOpacity=".55" />
                <stop offset="1" stopColor="#f8f4ff" stopOpacity=".7" />
              </linearGradient>
              <linearGradient id={`${id}-glaze`} x1="0" y1="0" x2="0" y2="1">
                <stop stopColor="#fffefc" stopOpacity=".66" />
                <stop offset="1" stopColor="#fffefc" stopOpacity="0" />
              </linearGradient>
            </defs>
            <path d={aperture} fill={`url(#${id}-porcelain)`} fillRule="evenodd" />
            <path d={aperture} fill="none" stroke={`url(#${id}-rim)`} strokeWidth=".7" />
            <path d="M27 5H73C86 5 94 12 95 25L83 29C82 21 78 17 70 17H30C20 17 17 20 17 30L5 27C5 13 12 5 27 5Z" fill={`url(#${id}-glaze)`} />
            <path d="M26 7H68M7 27V52" fill="none" stroke="#ffffff" strokeOpacity=".65" strokeWidth=".8" strokeLinecap="round" />
            <path d="M77 37V68C77 74 74 77 68 77H44" fill="none" stroke="#fcf8ff" strokeOpacity=".8" strokeWidth=".8" strokeLinecap="round" />
          </svg>
          <div className={styles.glassEdge} />
          <div className={styles.focusMark}><i /><i /><i /><i /></div>
        </div>
      </div>
    </div>
  );
}
