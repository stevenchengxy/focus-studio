"use client";

import { useEffect, useRef, useState } from "react";
import { INSTALLERS, installerPath } from "@/lib/installers";
import { ThemeToggle } from "@/components/theme/theme-toggle";
import { LocaleToggle } from "@/components/locale/locale-toggle";
import { useLocale } from "@/components/locale/locale-provider";
import { ProductVideo } from "./product-video";
import { TutorialVideos } from "./tutorial-videos";
import { useMarketingMotion } from "./use-marketing-motion";
import { FocusSculpture } from "./focus-sculpture";
import design from "./design-refinement.module.css";
import community from "./community-feature.module.css";
import { ArrowDown, ArrowUpRight, CirclePlay, Code2, Command, Download, Focus, Menu, Monitor, Play, Plus, X } from "lucide-react";

type Platform = "mac" | "windows" | "linux";
export function Brand({ dark = false }: { dark?: boolean }) {
  const { t } = useLocale();
  return <a className={`brand${dark ? " brand-dark" : ""}`} href="/" aria-label={t("Focus Studio home", "Focus Studio 首页")}><img className="brand-icon" src="/icons/focus-studio.svg" width="36" height="36" alt=""/><span>Focus Studio</span></a>;
}

export function FocusHome() {
  const { t } = useLocale();
  const [motion, setMotion] = useState(false);
  const [mobileMenu, setMobileMenu] = useState(false);
  const [demoVideoUrl, setDemoVideoUrl] = useState<string | null>(null);
  const [platform, setPlatform] = useState<Platform>("mac");
  const [downloadOpen, setDownloadOpen] = useState(false);
  const [release, setRelease] = useState<{platform:Platform;version:string;download_url:string;release_url:string}|null>(null);
  const [videoOpen, setVideoOpen] = useState(false);
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
    fetch("/api/config").then(r => r.ok ? r.json() : null).then((value: unknown) => {
      if (value && typeof value === "object" && "demoVideoUrl" in value && typeof value.demoVideoUrl === "string") setDemoVideoUrl(value.demoVideoUrl);
    }).catch(() => {});
    if (navigator.platform.toLowerCase().includes("win")) setPlatform("windows");
    else if (navigator.platform.toLowerCase().includes("linux")) setPlatform("linux");
    const openFromLink = () => { if (window.location.hash === "#download" || new URLSearchParams(window.location.search).get("download") === "1") setDownloadOpen(true); };
    openFromLink(); window.addEventListener("hashchange", openFromLink);
    return () => { reduced.removeEventListener("change", listener); window.removeEventListener("hashchange", openFromLink); };
  }, []);
  useEffect(() => { if (downloadOpen) dialogRef.current?.showModal(); else dialogRef.current?.close(); }, [downloadOpen]);
  useEffect(() => {
    if (videoOpen) { videoDialogRef.current?.showModal(); void videoRef.current?.play().catch(() => {}); }
    else { videoRef.current?.pause(); videoDialogRef.current?.close(); }
  }, [videoOpen]);
  useEffect(() => {
    if (!downloadOpen) return;
    const controller = new AbortController(); setRelease(null);
    fetch(`/api/releases?platform=${platform}&channel=preview`, {signal:controller.signal})
      .then(response => response.ok ? response.json() : null).then((value: unknown) => {
        if (controller.signal.aborted || !value || typeof value !== "object") return;
        const item = value as Record<string, unknown>;
        if (item.platform !== platform || typeof item.version !== "string" || !/^\d+\.\d+\.\d+$/.test(item.version) || typeof item.download_url !== "string" || typeof item.release_url !== "string") return;
        const download = new URL(item.download_url, window.location.origin), notes = new URL(item.release_url);
        if (download.origin !== window.location.origin || download.pathname !== `/api/download/${platform}` || download.username || download.password || download.hash ||
          notes.origin !== "https://github.com" || notes.username || notes.password || !notes.pathname.startsWith("/stevenchengxy/focus-studio/releases/tag/")) return;
        setRelease({platform, version:item.version, download_url:download.href, release_url:notes.href});
      }).catch(() => {});
    return () => controller.abort();
  }, [downloadOpen, platform]);
  const currentRelease = release?.platform === platform ? release : null;
  const desktopDownloadUrl = currentRelease?.download_url || installerPath(platform);

  return <div className={`focus-site ${design.refinedSite}${motion ? " has-motion" : " motion-paused"}`} ref={siteRef}>
    <a className="skip-link" href="#main">{t("Skip to content", "跳转到正文")}</a>
    <header className="site-header"><div className="nav-wrap"><Brand/>
      <nav aria-label={t("Main navigation", "主导航")} className={mobileMenu ? "main-nav is-open" : "main-nav"}>
        <a href="#possibilities" onClick={() => setMobileMenu(false)}>{t("Explore", "功能")}</a>
        <a href="#workflow" onClick={() => setMobileMenu(false)}>{t("Workflow", "工作流")}</a>
        <a href="/community">{t("Community", "作品社区")}</a>
        <a className="nav-account" href="/account" target="_top">{t("Sign in", "登录")}</a>
      </nav>
      <div className="nav-actions"><a className="sign-in" href="/account" target="_top">{t("Sign in", "登录")}</a><LocaleToggle/><ThemeToggle/><button className="button button-dark button-small" onClick={() => setDownloadOpen(true)}>{t("Free download", "免费下载")} <ArrowDown size={15}/></button><button className="mobile-menu" aria-label={mobileMenu ? t("Close navigation", "关闭导航") : t("Open navigation", "展开导航")} aria-expanded={mobileMenu} onClick={() => setMobileMenu(!mobileMenu)}>{mobileMenu ? <X/> : <Menu/>}</button></div>
    </div></header>
    <main id="main">
      <section className="hero section-wrap">
        <div className={design.heroAtmosphere} aria-hidden="true" data-motion-section><div className={design.lightField}/><div className={design.compositionFrame}><i/><i/><i/><i/></div><div className={design.heroSculpture}><FocusSculpture variant="hero" size="var(--focus-sculpture-size)"/></div><div className={design.orbitDot}/></div>
        <div className="hero-copy" data-reveal>
          <h1>{t("Your product.", "你的产品。")}<br/>{t("In its ", "值得")}<span className="best-light">{t("best light.", "出彩。")}<svg viewBox="0 0 590 25" preserveAspectRatio="none" aria-hidden="true"><path d="M6 17C169 3 374 4 581 14"/></svg></span></h1>
          <p className="hero-description">{t("Record. Refine. Show what makes your product special.", "录制，打磨，让产品亮点被看见。")}</p>
          <div className="hero-actions"><button className="button button-dark" onClick={() => setDownloadOpen(true)}>{t("Make your first demo", "开始制作 Demo")} <ArrowUpRight size={19}/></button><button className="button button-plain" onClick={() => setVideoOpen(true)}><CirclePlay size={21} strokeWidth={1.5}/>{t("See it in action", "看看实际效果")}</button></div>
          <p className="hero-note">{t("Free to create. Free to export.", "录制、剪辑与导出，目前全部免费。")}<span>{t("Mac + desktop previews", "Mac · Windows / Linux 预览版")}</span></p>
        </div>
        <ProductVideo motion={motion}/>
        <div className="hero-footnote"><span><Command size={14}/>{t("Crafted for Mac", "为 Mac 精心打造")}</span><span><Code2 size={15}/>{t("Works with Codex", "支持 Codex")}</span><a href="/community">{t("Made with Focus", "发现社区作品")} <ArrowUpRight size={14}/></a></div>
        <div className={design.focusThread} aria-hidden="true" data-motion-section><span/><div><i/></div><Focus size={16} strokeWidth={1}/><div><i/></div><span/></div>
      </section>
      <section className="possibilities section-wrap" id="possibilities">
        <div className="section-heading" data-reveal><div><h2>{t("Make the ordinary", "让平凡的操作")}<br/><span className="serif-word">{t("worth a second look.", "值得再看一眼。")}</span></h2></div></div>
        <div className="feature-editorial" data-reveal><div className="feature-art product-feature"><ProductVideo motion={motion} compact src="/media/focus-detail-lift.mp4" poster="/media/focus-detail-lift.jpg"/></div><div className="feature-copy"><span className="step-index">{t("01 / THE CAMERA", "01 / 镜头")}</span><h3>{t("A natural eye", "让视线自然聚焦")}<br/>{t("for the important bit.", "在重要的地方。")}</h3><p>{t("Smooth zooms. A spotlight on the details. A little depth when it matters.", "流畅缩放，局部强调，细节恰到好处。")}</p><div className="feature-tags"><span>{t("Smooth zoom", "平滑缩放")}</span><span>{t("Region effects", "局部特效")}</span><span>{t("Cursor polish", "鼠标优化")}</span></div></div></div>
        <div className="feature-editorial reverse" data-reveal><div className="feature-art product-feature editor-detail" data-motion-section><div className="editor-detail-window"><img src="/media/focus-studio-editor.jpg" alt={t("Focus Studio timeline with editable zoom, local emphasis and video tracks", "Focus Studio 的缩放、局部特效和视频编辑轨道")} loading="lazy" decoding="async"/></div></div><div className="feature-copy"><span className="step-index">{t("02 / THE EDIT", "02 / 剪辑")}</span><h3>{t("Find your rhythm.", "找到节奏。")}<br/>{t("Leave the waiting out.", "剪掉等待。")}</h3><p>{t("Trim, arrange and fine-tune. Undo whenever you need to.", "裁剪、排序、精细调整。随时撤销，放心尝试。")}</p><div className="feature-tags"><span>{t("Frame-level control", "逐帧控制")}</span><span>{t("Transitions", "转场特效")}</span><span>{t("Undo & redo", "撤销与重做")}</span></div></div></div>
      </section>
      <section className="editor-proof section-wrap" aria-labelledby="editor-proof-title" data-reveal><h2 id="editor-proof-title">{t("Make every frame ", "每一帧，都有")}<span className="serif-word">{t("yours.", "你的想法。")}</span></h2><div className={design.editorStage}><div className={design.editorContours} aria-hidden="true"/><figure className="editor-proof-stage"><img loading="lazy" decoding="async" src="/media/focus-studio-editor.jpg" alt={t("The Focus Studio Mac editor with a product preview, effect timeline and editing controls", "Focus Studio Mac 编辑器的产品预览、特效时间轴与编辑面板")}/></figure></div></section>
      <section className="ai-section" id="workflow"><div className="section-wrap ai-inner"><div className="ai-copy" data-reveal><h2>{t("Meet your", "认识你的")}<br/><span className="serif-word">{t("demo co-pilot.", "Demo 创作搭档。")}</span></h2><p>{t("Record and edit with Codex. Keep the final say.", "让 Codex 协助录制与剪辑，创作始终由你决定。")}</p><a href="/help#codex" className="text-link">{t("How the connection works", "了解如何连接")} <ArrowUpRight size={17}/></a></div><figure className={design.assistantProof} data-reveal><img src={t("/media/focus-assistant-en.png", "/media/focus-assistant-zh.png")} alt={t("The Focus Studio AI assistant, connected to Codex, with recording, editing and video creation actions", "Focus Studio AI 助手，已连接 Codex，提供录制、剪辑和视频生成入口")} width="1440" height="1440" loading="lazy" decoding="async"/></figure></div></section>
      <TutorialVideos/>
      <section className="film-section section-wrap" aria-labelledby="film-title" data-reveal><div className="film-copy"><h2 id="film-title">{t("A closer look", "近一点，")}<br/>{t("at ", "看见 ")}<span className="serif-word">Focus.</span></h2><button className="text-link" onClick={() => setVideoOpen(true)}>{t("Play the effect reel", "播放特效演示")} <CirclePlay size={19}/></button></div><button className="film-poster" onClick={() => setVideoOpen(true)} aria-label={t("Play Focus Studio effect reel", "播放 Focus Studio 特效演示")}><img src="/media/focus-studio-demo-flat.jpg" alt={t("Focus Studio effect preview", "Focus Studio 特效预览")} onError={event => { event.currentTarget.style.display = "none"; }}/><div className="film-fallback"><Focus size={100} strokeWidth={0.75}/><span>{t("Small details.", "细节虽小。")}<br/>{t("Big difference.", "效果不同。")}</span></div><span className="film-play"><Play size={25} fill="currentColor"/></span><span className="film-caption"><span>{t("FOCUS STUDIO / EFFECT REEL", "FOCUS STUDIO / 特效演示")}</span><span>{t("Watch", "观看")} <ArrowUpRight size={14}/></span></span></button></section>
      <section className={community.section} id="community"><div className={`section-wrap ${community.inner}`} data-reveal><div><span className="step-index">{t("MADE WITH FOCUS", "用 FOCUS 创作")}</span><h2>{t("Good ideas deserve", "让好作品")}<br/><span className="serif-word">{t("an audience.", "被看见。")}</span></h2><p>{t("Share a demo. Discover a different way to tell your story.", "分享你的 Demo，也发现不一样的表达。")}</p></div><div className={community.links}><a href="/community"><span><Focus size={20}/>{t("Explore the community", "浏览作品社区")}</span><ArrowUpRight size={22}/></a><a href="/community/new"><span><Plus size={20}/>{t("Share your work", "分享我的作品")}</span><ArrowUpRight size={22}/></a></div></div></section>
      <section className="faq-section section-wrap"><div><h2>{t("Good questions.", "你可能想知道。")}</h2></div><div className="faq-list">
        <details><summary>{t("Is Focus Studio free?", "Focus Studio 免费吗？")}<Plus size={17}/></summary><p>{t("Recording, editing and exporting are currently free. Optional AI services use your own provider account and may charge separately.", "目前录制、剪辑和导出全部免费。可选的 AI 服务使用你自己的服务商账户，可能产生单独费用。")}</p></details>
        <details><summary>{t("Do I need AI to use it?", "一定要连接 AI 才能使用吗？")}<Plus size={17}/></summary><p>{t("No. Record and edit directly in the Mac app. Connect Codex when you want help recording a workflow or refining an edit.", "不需要。你可以直接使用 Mac 软件录制和编辑；需要协助操作、录制或优化时，再连接 Codex。")}</p></details>
        <details><summary>{t("Can I use Windows or Linux?", "支持 Windows 和 Linux 吗？")}<Plus size={17}/></summary><p>{t("Installable desktop previews offer recording and essential edits. They require internet access and do not yet include the full Mac editor or native MCP. The Mac app requires macOS 15+.", "可下载安装桌面预览版，进行录制和基础编辑。预览版需要联网，暂不包含完整 Mac 编辑器和原生 MCP。Mac 版要求 macOS 15 或更高版本。")}</p><button className="text-link" onClick={() => {setPlatform("windows");setDownloadOpen(true);}}>{t("See downloads", "查看下载选项")} <ArrowUpRight size={14}/></button></details>
        <details><summary>{t("Where do my recordings go?", "我的录屏会保存在哪里？")}<Plus size={17}/></summary><p>{t("Mac projects stay on your device. Sharing to the community is your choice. Content you send to an AI provider is handled under that provider’s policies.", "Mac 项目保存在本机。是否分享到社区由你决定；发送给 AI 服务商的内容遵循该服务商的数据政策。")}</p><a href="/privacy" className="text-link">{t("Privacy overview", "隐私说明")} <ArrowUpRight size={14}/></a></details>
      </div></section>
      <section className="closing-section section-wrap" data-reveal data-motion-section><div className={design.closingArt}><FocusSculpture variant="closing" size="var(--focus-sculpture-size)"/></div><h2>{t("Now give it", "现在，给你的产品")}<br/><span className="serif-word">{t("a proper introduction.", "一次精彩亮相。")}</span></h2><button className="button button-dark" onClick={() => setDownloadOpen(true)}>{t("Download Focus Studio", "免费下载 Focus Studio")} <ArrowDown size={18}/></button><span className="closing-note">{t("Create freely. Make it yours.", "自由创作，让想法成片。")}</span></section>
    </main>
    <footer className="site-footer section-wrap"><div className="footer-top"><Brand/><div className="footer-links"><a href="#possibilities">{t("Explore", "功能")}</a><a href="/community">{t("Community", "作品社区")}</a><a href="/help">{t("Getting started", "快速上手")}</a><a href="/privacy">{t("Privacy", "隐私")}</a><a href="https://github.com/stevenchengxy/focus-studio" target="_blank" rel="noreferrer">GitHub <ArrowUpRight size={12}/></a></div></div><div className="footer-bottom"><span>© {new Date().getFullYear()} Focus Studio.</span><button onClick={() => window.scrollTo({top:0,behavior: motion ? "smooth" : "instant"})}>{t("Back to top", "返回顶部")} <ArrowUpRight size={13}/></button></div></footer>
    <dialog className="download-dialog" ref={dialogRef} aria-labelledby="download-title" onCancel={() => setDownloadOpen(false)} onClick={event => {if(event.target===event.currentTarget)setDownloadOpen(false);}}><div className="dialog-surface"><button className="dialog-close" aria-label={t("Close download options", "关闭下载选项")} onClick={() => setDownloadOpen(false)}><X size={20}/></button><span className="eyebrow">{t("FREE DOWNLOAD", "免费下载")}</span><h2 id="download-title">{t("A good place", "精彩作品，")}<br/>{t("to start.", "从这里开始。")}</h2><div className="platform-tabs" role="group" aria-label={t("Choose your platform", "选择操作系统")}>{(["mac","windows","linux"] as Platform[]).map(item=><button key={item} className={platform===item?"selected":""} aria-pressed={platform===item} onClick={()=>setPlatform(item)}>{item==="mac"?"macOS":item==="windows"?"Windows":"Linux"}</button>)}</div><div className="platform-content"><div className={`platform-icon${platform!=="mac"?" mint":""}`}><Monitor size={29}/></div><h3>{platform==="mac"?t("The full studio. On your Mac.", "完整创作体验，在你的 Mac 上。"):t("A desktop preview, ready to explore.", "桌面预览版，邀你体验。")}</h3><p>{platform==="mac"?t("Native recording, precise edits and your AI co-pilot.", "原生录屏、精细剪辑，还有你的 AI 搭档。"):t("Screen recording and essential edits. Internet required.", "支持录屏与基础编辑，需要联网。")}</p><a className="button button-dark" href={desktopDownloadUrl}>{t("Download for", "下载")} {platform==="mac"?"Mac":platform==="windows"?"Windows":"Linux"} · {INSTALLERS[platform].format}<Download size={17}/></a><small>{currentRelease&&<>v{currentRelease.version} · </>}{platform==="mac"?t("macOS 15+ · Apple silicon & Intel", "macOS 15+ · Apple 芯片与 Intel"):platform==="windows"?"Windows x64":"Linux x64 · AppImage"}<br/>{platform==="mac"?t("Preview build · Check installation notes", "预览版 · 请查看安装说明"):t("Preview · Full Mac editor and native MCP are not included", "预览版 · 暂不包含完整 Mac 编辑器和原生 MCP")}</small><a className="text-link" href={platform==="mac"?"/help#installation":"/help#desktop"}>{t("Installation notes", "安装说明")}<ArrowUpRight size={13}/></a></div>{currentRelease&&<a className="text-link" href={currentRelease.release_url} target="_blank" rel="noreferrer">{t("Release notes", "版本说明")}<ArrowUpRight size={13}/></a>}</div></dialog>
    <dialog className="video-dialog" ref={videoDialogRef} aria-label={t("Focus Studio effect reel", "Focus Studio 特效演示")} onCancel={()=>setVideoOpen(false)} onClick={event=>{if(event.target===event.currentTarget)setVideoOpen(false);}}><div className="video-dialog-surface"><div className="video-dialog-header"><span><Focus size={18}/>{t("Focus Studio / effect reel", "Focus Studio / 特效演示")}</span><button className="dialog-close" aria-label={t("Close video", "关闭视频")} onClick={()=>setVideoOpen(false)}><X size={20}/></button></div><video ref={videoRef} src={demoVideoUrl||"/media/focus-studio-demo-flat.mp4"} controls playsInline preload="none" poster="/media/focus-studio-demo-flat.jpg">{t("Your browser does not support this video.", "你的浏览器不支持此视频。")}<a href="/media/focus-studio-demo-flat.mp4">{t("Download the effect reel.", "下载演示视频。")}</a></video><p>{t("Actual renderer output using illustrative demo footage.", "使用示例内容展示软件实际渲染效果。")}</p></div></dialog>
  </div>;
}
