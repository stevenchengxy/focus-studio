import type { Metadata } from "next";
import "./globals.css";
import "./theme.css";
import { LocaleProvider } from "@/components/locale/locale-provider";
import { ThemeProvider } from "@/components/theme/theme-provider";
import { themeInitScript } from "@/components/theme/theme-settings";

export const metadata: Metadata = {
  manifest: "/manifest.webmanifest",
  title: "Focus Studio — Your product, in its best light",
  description:
    "Record a product demo. Shape the story with precise zooms, local emphasis and an AI editing assistant. Download for Mac, Windows or Linux. Create freely and share your work.",
  openGraph: {
    title: "Focus Studio — Your product, in its best light",
    description: "A little less editing. A lot more focus. Product demos, made with you and AI.",
    type: "website",
  },
  icons: {
    icon: "/favicon.svg",
    shortcut: "/favicon.svg",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head><script dangerouslySetInnerHTML={{ __html: themeInitScript }}/></head>
      <body className="antialiased"><LocaleProvider><ThemeProvider>{children}</ThemeProvider></LocaleProvider></body>
    </html>
  );
}
