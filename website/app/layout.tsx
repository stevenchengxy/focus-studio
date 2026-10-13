import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  manifest: "/manifest.webmanifest",
  title: "Focus Studio — Your product, in its best light",
  description:
    "Record a product demo. Shape the story with precise zooms, local emphasis and an AI editing assistant. Start on Mac, or try Browser Studio.",
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
    <html lang="en">
      <body className="antialiased">{children}</body>
    </html>
  );
}
