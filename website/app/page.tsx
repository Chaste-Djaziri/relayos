// Path: website/app/page.tsx
import "./page.css";

const macDownload = "https://github.com/Chaste-Djaziri/relayos/releases/download/nightly/RelayOS.dmg";
const releasesPage = "https://github.com/Chaste-Djaziri/relayos/releases/tag/nightly";

export default function Home() {
  return (
    <main>
      <nav className="nav">
        <a className="brand" href="#" aria-label="RelayOS homepage">
          <img className="brand-logo" src="/branding/relayos-white.png" alt="" />
          <span>RelayOS</span>
        </a>
        <div className="nav-links">
          <a href="#how">How it works</a>
          <a href="#security">Security</a>
          <a className="nav-cta" href="#download">Download</a>
        </div>
      </nav>
      <section className="hero">
        <div className="eyebrow"><span className="pulse" /> Private MCP access for your Mac</div>
        <h1>Your machine.<br /><em>Your tools.</em><br />One secure bridge.</h1>
        <p className="lede">RelayOS connects ChatGPT, Claude, Gemini, and other MCP clients to the tools on your Mac—with local approvals and no shared credentials.</p>
        <div className="actions">
          <a className="button primary" href={macDownload}>Download for macOS <span aria-hidden="true">↓</span></a>
          <a className="button ghost" href="#how">See how it works <span aria-hidden="true">→</span></a>
        </div>
        <p className="requirements">macOS 14 Sonoma or later · Apple Silicon (M1 or newer) · Windows coming soon</p>
      </section>
      <section className="signal">
        <div><strong>01</strong><span>Install once</span></div>
        <div><strong>02</strong><span>Approve locally</span></div>
        <div><strong>03</strong><span>Build from anywhere</span></div>
      </section>
      <section id="how" className="section">
        <div className="section-kicker">HOW IT WORKS</div>
        <h2>Everything you need.<br /><span>Nothing you don&apos;t.</span></h2>
        <div className="cards">
          <article><div className="card-number">01</div><h3>Run privately</h3><p>RelayOS keeps its MCP server on localhost and gives it an encrypted public endpoint through your own ngrok account.</p></article>
          <article><div className="card-number">02</div><h3>Approve with intent</h3><p>New connections and sensitive actions require your consent. Choose one-time, session, or saved approvals where supported.</p></article>
          <article><div className="card-number">03</div><h3>Guide with AI</h3><p>Connect an MCP-compatible assistant to inspect permitted context, highlight controls, and guide you on your Mac.</p></article>
        </div>
      </section>
      <section id="security" className="quote"><div className="quote-mark">“</div><p>Your credentials stay on your machine.<br />Your approvals stay in your hands.</p></section>
      <section id="download" className="download">
        <div>
          <div className="section-kicker">GET STARTED</div>
          <h2>Ready when you are.</h2>
          <p>Download RelayOS for Apple Silicon, drag the app to Applications, and launch it to begin setup.</p>
        </div>
        <div className="download-actions">
          <a className="button primary large" href={macDownload} aria-label="Download RelayOS DMG for macOS Apple Silicon">
            Download for macOS <span aria-hidden="true">↓</span>
          </a>
          <span className="button unavailable large" aria-label="RelayOS for Windows coming soon">
            Windows <span className="coming-soon">Coming Soon</span>
          </span>
        </div>
        <small>
          macOS 14+ · Apple Silicon · Free development release · <a href={releasesPage}>Release details and checksums</a>
          <br />Nightly builds are development releases and may not be notarized; macOS might require you to explicitly open the app in System Settings.
        </small>
      </section>
      <footer>
        <a className="brand" href="#"><img className="brand-logo" src="/branding/relayos-white.png" alt="" /><span>RelayOS</span></a>
        <span>Private tools for thoughtful automation.</span>
        <span>© 2026 RelayOS</span>
      </footer>
    </main>
  );
}
