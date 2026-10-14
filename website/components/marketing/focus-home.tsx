"use client";

import { useEffect, useRef, useState } from "react";
import { ThemeToggle } from "@/components/theme/theme-toggle";
import { ProductVideo } from "./product-video";
import { useMarketingMotion } from "./use-marketing-motion";
import { FocusSculpture } from "./focus-sculpture";
import design from "./design-refinement.module.css";
import { ArrowDown, ArrowRight, ArrowUpRight, Check, CirclePlay, Code2, Command, Download, Focus, Menu, Monitor, Play, Plus, Sparkles, X } from "lucide-react";

interface SiteConfig {
  billingConfigured?: boolean;
  macDownloadUrl?: string | null;
  windowsDownloadUrl?: string | null;
  linuxDownloadUrl?: string | null;
  demoVideoUrl?: string | null;
}

type Platform = "mac" | "windows" | "linux";

export function Brand({ dark = false }: { dark?: boolean }) {
  return <a className={`brand${dark ? " brand-dark" : ""}`} href="/" aria-label="Focus Studio home"><img className="brand-icon" src="/icons/icon-192.png" width="36" height="36" alt=""/><span>Focus Studio</span></a>;
}

export function FocusHome() {
  const [motion, setMotion] = useState(false);
  const [mobileMenu, setMobileMenu] = useState(false);
  const [config, setConfig] = useState<SiteConfig>({});
  const [platform, setPlatform] = useState<Platform>("mac");
  const [downloadOpen, setDownloadOpen] = useState(false);
  const [videoOpen, setVideoOpen] = useState(false);
  const [plan, setPlan] = useState<"annual" | "monthly">("annual");
  const [checkoutBusy, setCheckoutBusy] = useState(false);
  const [checkoutMessage, setCheckoutMessage] = useState("");
  const siteRef = useRef<HTMLDivElement>(null);
  useMarketingMotion(siteRef, motion);
  const dialogRef = useRef<HTMLDialogElement>(null);
  const videoDialogRef = useRef<HTMLDialogElement>(null);
  const videoRef = useRef<HTMLVideoElement>(null);

  useEffect(() => {
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
    setMotion(!reduced.matches);
    const listener = () => setMotion(!reduced.matches);
    reduced.addEventListener("change", listener);
    fetch("/api/config").then((r) => r.ok ? r.json() : {}).then(setConfig).catch(() => {});
    if (navigator.platform.toLowerCase().includes("win")) setPlatform("windows");
    else if (navigator.platform.toLowerCase().includes("linux")) setPlatform("linux");
    return () => reduced.removeEventListener("change", listener);
  }, []);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (downloadOpen) dialog?.showModal(); else dialog?.close();
  }, [downloadOpen]);

  useEffect(() => {
    if (videoOpen) { videoDialogRef.current?.showModal(); void videoRef.current?.play().catch(() => {}); }
    else { videoRef.current?.pause(); videoDialogRef.current?.close(); }
  }, [videoOpen]);

  async function checkout() {
    setCheckoutMessage("");
    if (!config.billingConfigured) {
      setCheckoutMessage("Subscriptions are not open yet. You can create an account and try your first export free.");
      return;
    }
    setCheckoutBusy(true);
    try {
      const response = await fetch("/api/billing/checkout", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ plan: plan === "annual" ? "yearly" : "monthly" }) });
      const data = await response.json() as { url?: string; checkoutUrl?: string; error?: string | { code?: string; message?: string }; message?: string; loginUrl?: string };
      if (response.status === 401) { window.location.href = data.loginUrl || "/account"; return; }
      if (!response.ok) throw new Error((typeof data.error === "string" ? data.error : data.error?.message) || data.message || "Checkout is unavailable. Please try again later.");
      const next = data.url || data.checkoutUrl;
      if (!next) throw new Error("Checkout is unavailable. Please try again later.");
      const url = new URL(next, window.location.origin);
      if (url.protocol !== "https:" && url.origin !== window.location.origin) throw new Error("Checkout returned an invalid address.");
      window.location.href = url.href;
    } catch (error) {
      setCheckoutMessage(error instanceof Error ? error.message : "Checkout is unavailable. Please try again later.");
    } finally { setCheckoutBusy(false); }
  }

  const desktopDownloadUrl = platform === "windows" ? config.windowsDownloadUrl : config.linuxDownloadUrl;
  const hasDesktopPreview = Boolean(config.windowsDownloadUrl || config.linuxDownloadUrl);

  return (
    <div className={`focus-site ${design.refinedSite}${motion ? " has-motion" : " motion-paused"}`} ref={siteRef}>
      <a className="skip-link" href="#main">Skip to content</a>
      <header className="site-header">
        <div className="nav-wrap"><Brand />
          <nav aria-label="Main navigation" className={mobileMenu ? "main-nav is-open" : "main-nav"}>
            <a href="#possibilities" onClick={() => setMobileMenu(false)}>The possibilities</a>
            <a href="#workflow" onClick={() => setMobileMenu(false)}>The workflow</a>
            <a href="#pricing" onClick={() => setMobileMenu(false)}>Pricing</a>
          </nav>
          <div className="nav-actions"><a className="sign-in" href="/account">Sign in</a><ThemeToggle/><button className="button button-dark button-small" onClick={() => setDownloadOpen(true)}>Get Focus Studio <ArrowDown size={15}/></button><button className="mobile-menu" aria-label={mobileMenu ? "Close navigation" : "Open navigation"} aria-expanded={mobileMenu} onClick={() => setMobileMenu(!mobileMenu)}>{mobileMenu ? <X/> : <Menu/>}</button></div>
        </div>
      </header>

      <main id="main">
        <section className="hero section-wrap">
          <div className={design.heroAtmosphere} aria-hidden="true" data-motion-section>
            <div className={design.lightField}/>
            <div className={design.compositionFrame}><i/><i/><i/><i/></div>
            <div className={design.heroSculpture}><FocusSculpture variant="hero" size="var(--focus-sculpture-size)"/></div>
            <div className={design.orbitDot}/>
          </div>
          <div className="hero-copy" data-reveal>

            <h1>Your product.<br/>In its <span className="best-light">best light.<svg viewBox="0 0 590 25" preserveAspectRatio="none" aria-hidden="true"><path d="M6 17C169 3 374 4 581 14"/></svg></span></h1>
            <p className="hero-description">Record. Refine. Show what makes your product special.</p>
            <div className="hero-actions"><button className="button button-dark" onClick={() => setDownloadOpen(true)}>Make your first demo <ArrowUpRight size={19}/></button><button className="button button-plain" onClick={() => setVideoOpen(true)}><CirclePlay size={21} strokeWidth={1.5}/> See it in action</button></div>
            <p className="hero-note">One free export. No card required. <span>{hasDesktopPreview ? "Mac + desktop previews" : "macOS 15+"}</span></p>
          </div>

          <ProductVideo motion={motion}/>
          <div className="hero-footnote"><span><Command size={14}/> Crafted for Mac</span><span><Code2 size={15}/> Works with Codex</span><a href="/studio">Try Browser Studio <ArrowUpRight size={14}/></a></div>
          <div className={design.focusThread} aria-hidden="true" data-motion-section><span/><div><i/></div><Focus size={16} strokeWidth={1}/><div><i/></div><span/></div>
        </section>

        <section className="possibilities section-wrap" id="possibilities">
          <div className="section-heading" data-reveal><div><h2>Make the ordinary<br/><span className="serif-word">worth a second look.</span></h2></div></div>
          <div className="feature-editorial" data-reveal><div className="feature-art product-feature"><ProductVideo motion={motion} compact/></div><div className="feature-copy"><span className="step-index">01 / THE CAMERA</span><h3>A natural eye<br/>for the important bit.</h3><p>Smooth zooms. A spotlight on the details. A little depth when it matters.</p><div className="feature-tags"><span>Smooth zoom</span><span>Region effects</span><span>Cursor polish</span></div></div></div>
          <div className="feature-editorial reverse" data-reveal><div className="feature-art product-feature editor-detail" data-motion-section><div className="editor-detail-window"><img src="/media/focus-studio-editor.jpg" alt="Focus Studio timeline with editable zoom, local emphasis and video tracks" loading="lazy" decoding="async"/></div></div><div className="feature-copy"><span className="step-index">02 / THE EDIT</span><h3>Find your rhythm.<br/>Leave the waiting out.</h3><p>Trim, arrange and fine-tune. Undo whenever you need to.</p><div className="feature-tags"><span>Frame-level control</span><span>Transitions</span><span>Undo & redo</span></div></div></div>
        </section>

        <section className="editor-proof section-wrap" aria-labelledby="editor-proof-title" data-reveal><h2 id="editor-proof-title">Make every frame <span className="serif-word">yours.</span></h2><div className={design.editorStage}><div className={design.editorContours} aria-hidden="true"/><figure className="editor-proof-stage"><img loading="lazy" decoding="async" src="/media/focus-studio-editor.jpg" alt="The actual Focus Studio Mac editor with a product preview, effect timeline and editing controls"/></figure></div></section>

        <section className="ai-section" id="workflow"><div className="section-wrap ai-inner"><div className="ai-copy" data-reveal><h2>Meet your<br/><span className="serif-word">demo co-pilot.</span></h2><p>Record and edit with Codex. Keep the final say.</p><div className="ai-steps"><div><span>1</span><p><b>Give it a direction.</b></p></div><div><span>2</span><p><b>Connect through MCP.</b></p></div><div><span>3</span><p><b>Keep the final say.</b></p></div></div><a href="/help#codex" className="text-link">How the connection works <ArrowUpRight size={17}/></a></div><div className="ai-visual" data-reveal data-motion-section><div className="ai-orbit orbit-a"/><div className="ai-orbit orbit-b"/><div className="conversation"><div className="conversation-top"><span className="ai-spark"><Sparkles size={17}/></span><div>Focus assistant<small>Connected to your workflow</small></div><span className="conversation-status"/></div><div className="conversation-user">Make the onboarding feel effortless. Cut the pauses and bring the invite button into focus.</div><div className="conversation-reply"><span className="ai-spark"><Sparkles size={14}/></span><div>Let’s make every step feel intentional.</div></div><div className="conversation-tools"><div><Check size={13}/><span>Trim the pauses</span><small>Timeline</small></div><div><Check size={13}/><span>Spotlight the invitation</span><small>Effects</small></div><div><Check size={13}/><span>Keep the original take</span><small>Working copy</small></div></div><div className="conversation-preview"><div className="conversation-preview-icon"><Play fill="currentColor" size={19}/></div><div>Your story, with a little more polish.<small>Preview before exporting</small></div><ArrowUpRight size={17}/></div><div className="conversation-composer">What would you like to change?<span><ArrowUpRight size={14}/></span></div></div><span className="illustration-note">Illustrative workflow · Codex connection required</span></div></div></section>

        <section className="film-section section-wrap" aria-labelledby="film-title" data-reveal><div className="film-copy"><h2 id="film-title">A closer look<br/>at <span className="serif-word">Focus.</span></h2><button className="text-link" onClick={() => setVideoOpen(true)}>Play the effect reel <CirclePlay size={19}/></button></div><button className="film-poster" onClick={() => setVideoOpen(true)} aria-label="Play Focus Studio effect reel"><img src="/media/focus-studio-demo-flat.jpg" alt="Focus Studio effect preview" onError={(event) => { event.currentTarget.style.display = "none"; }}/><div className="film-fallback"><Focus size={100} strokeWidth={0.75}/><span>Small details.<br/>Big difference.</span></div><span className="film-play"><Play size={25} fill="currentColor"/></span><span className="film-caption"><span>FOCUS STUDIO / EFFECT REEL</span><span>Watch <ArrowUpRight size={14}/></span></span></button></section>

        <section className="pricing-section" id="pricing"><div className="section-wrap"><div className="pricing-heading" data-reveal><div><h2>Your first export<br/>is <span className="serif-word">on us.</span></h2></div></div><div className="pricing-grid"><div className="free-plan" data-reveal><h3>First look</h3><div className="plan-price">$0<span>to get started</span></div><p>One successful export per account.</p><a className="button button-outline" href="/account">Create your account <ArrowUpRight size={17}/></a><div className="plan-details"><span><Check size={15}/> No card required</span><span><Check size={15}/> Preview and edit before you export</span></div></div><div className="pro-plan" data-reveal><div className="pro-top"><span className="plan-badge">Focus Studio Pro</span></div><div className="billing-switch" role="group" aria-label="Billing interval"><button className={plan === "annual" ? "selected" : ""} aria-pressed={plan === "annual"} onClick={() => {setPlan("annual");setCheckoutMessage("");}}>Yearly <span>Save 69%</span></button><button className={plan === "monthly" ? "selected" : ""} aria-pressed={plan === "monthly"} onClick={() => {setPlan("monthly");setCheckoutMessage("");}}>Monthly</button></div><div className="plan-price" aria-live="polite">${plan === "annual" ? "9" : "29"}<span>/ month</span></div><p className="billing-description">{plan === "annual" ? "$108 billed once a year. Taxes may apply." : "$29 billed monthly. Taxes may apply."}</p><button className="button button-dark" disabled={checkoutBusy} onClick={checkout}>{checkoutBusy ? "Opening checkout…" : config.billingConfigured ? "Get Focus Studio Pro" : "View subscription availability"}<ArrowUpRight size={17}/></button><div className="plan-details"><span><Check size={15}/> Export beyond your first demo</span><span><Check size={15}/> Monthly or annual billing</span><span><Check size={15}/> AI provider usage billed separately</span></div>{checkoutMessage && <div className="checkout-message" role="status">{checkoutMessage}<a href="/account">Go to your account <ArrowRight size={13}/></a></div>}</div></div><p className="pricing-note">Editing stays local. Export requires an account and an internet connection. Browser Studio is a separate, lighter beta.</p></div></section>

        <section className="faq-section section-wrap"><div><h2>Good questions.</h2></div><div className="faq-list"><details><summary>Do I need AI to use Focus Studio?<Plus size={17}/></summary><p>No. Record and edit directly with the native Mac app. Connect Codex when you want an assistant to help record a workflow, adjust an edit or prepare an export.</p></details><details><summary>Can I use it on Windows or Linux?<Plus size={17}/></summary><p>{hasDesktopPreview ? "Windows and Linux desktop previews offer recording and essential edits. Check the download options for available builds. The full editor and Codex MCP currently require macOS 15+." : "Browser Studio offers recording and essential edits on Windows and Linux. Desktop preview builds are in preparation. The full editor and Codex MCP currently require macOS 15+."}</p><a href="/studio" className="text-link">Open Browser Studio <ArrowUpRight size={14}/></a></details><details><summary>How does the free export work?<Plus size={17}/></summary><p>Create an account to get one successful export. An unsuccessful export should not use your allowance. Export requires an internet connection to verify your account. Additional exports require an active subscription once billing is available.</p></details><details><summary>Where do my recordings go?<Plus size={17}/></summary><p>The native editor stores your projects on your Mac. AI generation and Codex are optional connections; content you send to them is processed by the provider you choose. Browser Studio processes media in your browser.</p><a href="/privacy" className="text-link">Read the privacy overview <ArrowUpRight size={14}/></a></details><details><summary>Is AI video generation included in Pro?<Plus size={17}/></summary><p>AI model usage is separate from your Focus Studio subscription. Connect your own supported provider and choose a model before generating. Review the generation request and estimated cost before continuing.</p></details></div></section>

        <section className="closing-section section-wrap" data-reveal data-motion-section><div className={design.closingArt}><FocusSculpture variant="closing" size="var(--focus-sculpture-size)"/></div><h2>Now give it<br/>a <span className="serif-word">proper introduction.</span></h2><button className="button button-dark" onClick={() => setDownloadOpen(true)}>Get Focus Studio <ArrowDown size={18}/></button><span className="closing-note">Start with one free export.</span></section>
      </main>

      <footer className="site-footer section-wrap"><div className="footer-top"><div><Brand/></div><div className="footer-links"><a href="#possibilities">Explore</a><a href="#pricing">Pricing</a><a href="/studio">Browser Studio <span>Beta</span></a><a href="/help">Getting started</a><a href="/privacy">Privacy</a><a href="https://github.com/stevenchengxy/focus-studio" target="_blank" rel="noreferrer">GitHub <ArrowUpRight size={12}/></a></div></div><div className="footer-bottom"><span>© {new Date().getFullYear()} Focus Studio.</span><button onClick={() => window.scrollTo({top:0,behavior: motion ? "smooth" : "instant"})}>Back to top <ArrowUpRight size={13}/></button></div></footer>

      <dialog className="download-dialog" ref={dialogRef} onCancel={() => setDownloadOpen(false)} onClick={(event) => { if (event.target === event.currentTarget) setDownloadOpen(false); }}><div className="dialog-surface"><button className="dialog-close" aria-label="Close download options" onClick={() => setDownloadOpen(false)}><X size={20}/></button><span className="eyebrow">FIND YOUR FOCUS</span><h2>A good place<br/>to start.</h2><div className="platform-tabs" role="group" aria-label="Choose your platform">{(["mac","windows","linux"] as Platform[]).map((item) => <button key={item} className={platform === item ? "selected" : ""} aria-pressed={platform === item} onClick={() => setPlatform(item)}>{item === "mac" ? "macOS" : item === "windows" ? "Windows" : "Linux"}</button>)}</div>{platform === "mac" ? <div className="platform-content"><div className="platform-icon"><Monitor size={29}/></div><h3>The full studio. On your Mac.</h3><p>Native screen recording, precise editing, local effects and your AI co-pilot.</p>{config.macDownloadUrl ? <a className="button button-dark" href={config.macDownloadUrl}>Download for Mac <Download size={17}/></a> : <a className="button button-dark" href="https://github.com/stevenchengxy/focus-studio/releases" target="_blank" rel="noreferrer">View Mac releases <ArrowUpRight size={17}/></a>}<small>macOS 15+ · Apple silicon & Intel<br/>Preview build. See installation notes before opening.</small><a className="text-link" href="/help#installation">Installation notes <ArrowUpRight size={13}/></a></div> : <div className="platform-content"><div className="platform-icon mint"><Monitor size={29}/></div><h3>{desktopDownloadUrl ? "A new desktop. The same focus." : "Meet Browser Studio."}</h3><p>{desktopDownloadUrl ? "Screen recording and essential edits, in a desktop preview." : "Record and edit in a modern browser. A desktop preview is in preparation."}</p>{desktopDownloadUrl ? <><a className="button button-dark" href={desktopDownloadUrl}>Download for {platform === "windows" ? "Windows" : "Linux"} <Download size={17}/></a><small>Preview · {platform === "windows" ? "Windows x64" : "Linux x64 · AppImage"} · Internet required.<br/>Full Mac editor and Codex MCP are separate.</small><a className="text-link" href="/studio">Try it in your browser <ArrowUpRight size={13}/></a></> : <><a className="button button-dark" href="/studio">Open Browser Studio <ArrowUpRight size={17}/></a><small>Beta · Modern browser required.<br/>Full Mac editor and Codex MCP are separate.</small></>}</div>}</div></dialog>
      <dialog className="video-dialog" ref={videoDialogRef} onCancel={() => setVideoOpen(false)} onClick={(event) => {if(event.target === event.currentTarget) setVideoOpen(false);}}><div className="video-dialog-surface"><div className="video-dialog-header"><span><Focus size={18}/> Focus Studio / effect reel</span><button className="dialog-close" aria-label="Close video" onClick={() => setVideoOpen(false)}><X size={20}/></button></div><video ref={videoRef} src={config.demoVideoUrl || "/media/focus-studio-demo-flat.mp4"} controls playsInline preload="none" poster="/media/focus-studio-demo-flat.jpg">Your browser does not support this video. <a href="/media/focus-studio-demo-flat.mp4">Download the effect reel.</a></video><p>Actual renderer output using illustrative demo footage.</p></div></dialog>
    </div>
  );
}
