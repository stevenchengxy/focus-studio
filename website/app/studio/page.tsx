import { DesktopGate } from "./desktop-gate";
import "./studio.css";
import "./studio-appearance.css";

export const metadata = {
  title: "Focus Studio Desktop",
  description: "Download Focus Studio to record and edit on your desktop.",
};

export default function StudioPage() { return <DesktopGate />; }
