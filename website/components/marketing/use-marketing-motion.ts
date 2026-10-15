"use client";

import { useEffect, type RefObject } from "react";

/** Reveal on either scroll direction; pause decorative loops outside the viewport. */
export function useMarketingMotion(scope: RefObject<HTMLDivElement | null>, enabled: boolean) {
  useEffect(() => {
    const root = scope.current;
    if (!root) return;

    const elements = Array.from(root.querySelectorAll<HTMLElement>("[data-reveal], [data-motion-section]"));
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
    const visibility = new Map<HTMLElement, boolean>();
    const motionAllowed = () => enabled && !reducedMotion.matches;
    const sync = () => {
      const active = motionAllowed();
      for (const element of elements) {
        const visible = visibility.get(element) === true;
        if (!active || (visible && !document.hidden)) element.dataset.revealed = "true";
        element.style.setProperty("--scene-play-state", active && visible && !document.hidden ? "running" : "paused");
      }
    };

    // Set the initially visible content before enabling reveal styles. Tall sections
    // need only enter the viewport, rather than reaching a percentage threshold.
    const refreshPreference = () => {
      const active = motionAllowed();
      for (const element of elements) {
        const bounds = element.getBoundingClientRect();
        const visible = bounds.bottom > 0 && bounds.top < window.innerHeight;
        visibility.set(element, visible);
        if (!active || visible) element.dataset.revealed = "true";
        else if (bounds.bottom < -64 || bounds.top > window.innerHeight + 64) delete element.dataset.revealed;
      }
      root.dataset.motionReady = String(active);
      sync();
    };

    if (!("IntersectionObserver" in window)) {
      root.dataset.motionReady = "false";
      elements.forEach((element) => element.style.setProperty("--scene-play-state", "paused"));
      return;
    }

    const revealObserver = new IntersectionObserver((entries) => {
      for (const entry of entries) visibility.set(entry.target as HTMLElement, entry.isIntersecting);
      sync();
    }, { threshold: 0 });

    // The separate outer boundary prevents a translated element from repeatedly
    // hiding and revealing at the viewport edge. Visible content never fades out.
    const rearmObserver = new IntersectionObserver((entries) => {
      if (!motionAllowed()) return;
      for (const entry of entries) {
        if (!entry.isIntersecting) delete (entry.target as HTMLElement).dataset.revealed;
      }
    }, { threshold: 0, rootMargin: "64px 0px" });

    refreshPreference();
    elements.forEach((element) => {
      revealObserver.observe(element);
      rearmObserver.observe(element);
    });
    reducedMotion.addEventListener("change", refreshPreference);
    document.addEventListener("visibilitychange", sync);

    return () => {
      revealObserver.disconnect();
      rearmObserver.disconnect();
      reducedMotion.removeEventListener("change", refreshPreference);
      document.removeEventListener("visibilitychange", sync);
      root.dataset.motionReady = "false";
      elements.forEach((element) => element.style.setProperty("--scene-play-state", "paused"));
    };
  }, [scope, enabled]);
}
