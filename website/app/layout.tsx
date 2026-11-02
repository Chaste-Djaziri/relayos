import "./page.css";

export const metadata = {
  title: "RelayOS - Private tools for thoughtful automation",
  description: "Connect AI assistants to your Mac with local approvals. RelayOS for Windows is coming soon.",
};

export default function Layout({ children }: { children: React.ReactNode }) {
  return <html lang="en"><body>{children}</body></html>;
}
