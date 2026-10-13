import { BrowserStudio } from "./studio";
import "./studio.css";

export const metadata = {
  title: "Browser Studio beta — Focus Studio",
  description: "Record or import a video, trim the good parts, add a focus effect and export in your browser.",
};

export default function StudioPage() { return <BrowserStudio />; }
