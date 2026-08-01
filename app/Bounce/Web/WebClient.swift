import Foundation

/// Serves the desktop client — a single static `index.html` from the app bundle.
///
/// One file with inlined CSS and JS, no build step and no npm, because this has
/// to stay maintainable inside an Xcode project that is generated from
/// `project.yml`. Adding a JavaScript toolchain to a repo whose only build is
/// `xcodegen generate && xcodebuild` buys nothing here.
enum WebClient {

    static func page() -> HTTPResponse {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html"),
              let markup = try? String(contentsOf: url, encoding: .utf8)
        else {
            return .html(resourceMissingPage)
        }
        return .html(markup)
    }

    /// Shown when `index.html` isn't in the bundle.
    ///
    /// This exists because the failure it reports is **silent** otherwise, and
    /// has already happened once in this repo: XcodeGen has no `resources:`
    /// target key, so declaring one is ignored without a warning and the files
    /// never reach Copy Bundle Resources (`CLAUDE.md`, trap 1). Rather than a
    /// blank page and a confusing debugging session, say exactly what's wrong.
    private static let resourceMissingPage = """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Bounce</title>
    <style>
      body { font: 15px/1.6 -apple-system, system-ui, sans-serif; margin: 0;
             display: grid; place-items: center; min-height: 100vh;
             background: #111; color: #eee; }
      div { max-width: 34rem; padding: 2rem; }
      code { background: #222; padding: .15em .4em; border-radius: 4px; }
      h1 { font-size: 1.1rem; }
    </style></head>
    <body><div>
      <h1>The desktop client didn't ship in this build</h1>
      <p><code>index.html</code> is not in the app bundle. The server is running
      correctly &mdash; the resource wasn't copied.</p>
      <p>Check that <code>app/project.yml</code> lists the client directory under
      <code>sources:</code> with an explicit <code>buildPhase: resources</code>,
      then run <code>xcodegen generate</code> and rebuild. XcodeGen has no
      top-level <code>resources:</code> key and ignores one silently.</p>
    </div></body></html>
    """
}
