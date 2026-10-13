import { ArrowLeft } from "lucide-react";
import { Brand } from "@/components/marketing/focus-home";

export const metadata = {title: "Privacy overview — Focus Studio"};

export default function PrivacyPage() {
  return <main className="document-shell"><Brand/><span className="eyebrow">PRIVACY OVERVIEW</span><h1>Your story.<br/>Your recordings.</h1><p>This page describes how the current preview is designed to handle recordings, accounts and connected services. It is a product data overview, not a claim of certification.</p>
    <section><h2>Your video stays local</h2><p>The native Focus Studio application stores its recording projects on your Mac. Browser Studio works with video inside your browser; its recording and export workflow does not upload the footage to this website’s server.</p><p>Local browser previews are temporary and can be lost when the page closes. A rendered export is saved in this browser’s local storage before export confirmation, so an interrupted confirmation can be retried. The latest saved export stays on this device until you replace it with another export, choose “Remove saved copy from browser,” or clear site storage. This recovery copy is not uploaded.</p></section>
    <section><h2>Account and export records</h2><p>The website uses account identity to track your free export allowance and subscription entitlement. The service records an account identifier, an email address when available, export reservations and their completion state. A reservation can include a project identifier; it does not require the video itself.</p></section>
    <section><h2>Optional AI connections</h2><p>Codex and AI media generation are separate connections. When you use them, the prompts, screenshots or other context you choose to send may be processed by that provider under its policies. Configure these connections only if you want their assistance.</p></section>
    <section><h2>Payments</h2><p>When payments are enabled, checkout is handled by the configured payment provider. Focus Studio stores subscription identifiers and status so it can determine export access. Payment card details are entered with the payment provider, not in the editor.</p></section>
    <section><h2>Hosting and sign-in</h2><p>This website is hosted through Sites. Its hosting and available sign-in services may process technical connection information needed to serve the site and authenticate an account. Only the sign-in options shown in the account experience are enabled.</p></section>
    <section><h2>Questions and requests</h2><p>Use the <a href="https://github.com/stevenchengxy/focus-studio/issues">project’s issue tracker</a> for product questions. Do not include private recordings, API keys, payment information or sensitive account details in a public issue.</p></section>
    <a className="document-back" href="/"><ArrowLeft size={15}/> Back to Focus Studio</a>
  </main>;
}
