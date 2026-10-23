import "./page.css";
export const metadata = { title: "RelayOS — Private tools for thoughtful automation", description: "Connect your AI clients to your Mac with local approvals." };
export default function Layout({ children }: { children: React.ReactNode }) {
  return <html lang="en"><body>{children}</body></html>;
}
