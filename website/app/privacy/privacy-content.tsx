'use client';
import { ArrowLeft } from 'lucide-react';
import { Brand } from '@/components/marketing/focus-home';
import { ThemeToggle } from '@/components/theme/theme-toggle';
import { LocaleToggle } from '@/components/locale/locale-toggle';
import { useLocale } from '@/components/locale/locale-provider';

export default function PrivacyContent() {
  const { t } = useLocale();
  return <main className="document-shell"><div className="document-nav"><Brand/><div style={{display:'flex',alignItems:'center',gap:14}}><LocaleToggle/><ThemeToggle/></div></div>
    <span className="eyebrow">{t('PRIVACY OVERVIEW', '隐私说明')}</span><h1>{t('Your story.', '你的故事。')}<br/>{t('Your recordings.', '你的录屏。')}</h1>
    <p>{t('How the current product handles recordings, accounts and connected services.', '了解当前产品如何处理录屏、账户和第三方服务中的数据。')}</p>
    <section><h2>{t('Local recordings', '本地录制')}</h2><p>{t('The Mac app stores projects and media on your device. Recording and editing do not automatically publish footage to this website. Windows and Linux preview sessions are temporary: export and save your work before closing the app.', 'Mac 软件将项目与素材保存在本机。录制和编辑不会自动将画面发布到官网。Windows 和 Linux 预览版的会话为临时内容，请在关闭软件前导出并保存。')}</p></section>
    <section><h2>{t('Community sharing', '社区分享')}</h2><p>{t('Selecting a video only previews it on your device. Saving a private draft uploads an account-only copy to the site’s storage. Publishing makes the video, thumbnail, title, description, product link and creator name public. Public work can be downloaded and reused under the sharing license.', '选择视频只会在本机预览；保存私密草稿会上传一份仅自己可见的副本到网站存储。发布后，视频、缩略图、标题、说明、产品链接与创作者名称会公开展示。公开作品可按分享许可被下载和复用。')}</p><p>{t('Manage, unpublish or delete your community copy in My shared work. Unpublishing stops new public access on this site; it cannot remove copies already downloaded. Check recordings for private messages, customer data and credentials before sharing.', '在“我分享的作品”中管理、取消发布或删除社区副本。取消发布会停止本站的新公开访问，但无法移除已被下载的副本。分享前，请检查是否包含私人消息、客户资料或密钥。')}</p></section>
    <section><h2>{t('Community review', '社区审核')}</h2><p>{t('Reports are private and available to authorized moderators. Moderators can review reported or held videos, even if an author has since unpublished them. Unrelated private drafts are not accessible through moderation tools.', '举报内容仅供授权管理员查看。管理员可以审核已被举报或暂停发布的视频，即使作者随后取消发布；审核工具不能访问其他无关的私密草稿。')}</p></section>
    <section><h2>{t('Accounts and devices', '账户与设备')}</h2><p>{t('Sign-in identifies the owner of community posts and connected devices. The service stores an account identifier, an email address when available, device names and connection records. You can disconnect approved devices from your account page. Recording, editing and exporting are currently free.', '登录用于确认社区作品和已连接设备的归属。服务会保存账户标识、可用的邮箱地址、设备名称与连接记录。你可以在账户页断开已批准的设备。目前录制、剪辑和导出全部免费。')}</p></section>
    <section><h2>{t('Optional AI services', '可选的 AI 服务')}</h2><p>{t('Codex and AI generation providers are optional connections. Prompts, screenshots, narration scripts or other context you send are processed under that provider’s policies. Your API keys are configured in the desktop app. Review the provider and requested content before generating media; its usage fees are separate.', 'Codex 与 AI 生成服务为可选连接。你发送的提示词、截图、旁白文案及其他上下文，遵循所选服务商的数据政策。API 密钥在桌面软件中配置。生成前请检查服务商与请求内容；其用量费用单独计算。')}</p></section>
    <section><h2>{t('Hosting and sign-in', '托管与登录')}</h2><p>{t('This website is hosted through Sites and uses ChatGPT sign-in. Hosting, sign-in and linked media services may process technical connection information needed to serve content and authenticate your account.', '本网站通过 Sites 托管，并使用 ChatGPT 登录。托管、登录及外部媒体服务可能处理用于提供内容和验证账户的技术连接信息。')}</p></section>
    <section><h2>{t('Questions', '问题与反馈')}</h2><p>{t('Contact us through the ', '你可以通过 ')}<a href="https://github.com/stevenchengxy/focus-studio/issues">{t('project issue tracker', '项目问题反馈页')}</a>{t('. Do not put private recordings, API keys or sensitive account details in a public issue.', ' 联系我们。请勿在公开问题中附上私人录屏、API 密钥或敏感账户信息。')}</p></section>
    <a className="document-back" href="/"><ArrowLeft size={15}/>{t('Back to Focus Studio', '返回 Focus Studio')}</a>
  </main>;
}
