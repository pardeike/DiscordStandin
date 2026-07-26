import AppKit
import DiscordStandinCore
import WebKit

@MainActor
enum LoginApplication {
  private static var retainedDelegate: LoginAppDelegate?

  static func run() {
    let application = NSApplication.shared
    let delegate = LoginAppDelegate()
    retainedDelegate = delegate
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
  }
}

@MainActor
private final class LoginAppDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = LoginViewController(credentials: KeychainCredentialStore())
    let window = NSWindow(contentViewController: controller)
    window.title = "DiscordStandin Login"
    window.setContentSize(NSSize(width: 980, height: 720))
    window.minSize = NSSize(width: 720, height: 560)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.center()
    window.makeKeyAndOrderFront(nil)
    self.window = window
    NSApplication.shared.activate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

@MainActor
private final class LoginViewController: NSViewController, WKNavigationDelegate {
  private let credentials: any CredentialStore
  private let statusLabel = NSTextField(
    labelWithString: "Sign in with Discord. Complete 2FA or any challenge in this window.")
  private let progress = NSProgressIndicator()
  private var webView: WKWebView!
  private var messageHandler: TokenMessageHandler!
  private var tokenBeingValidated: String?
  private var rejectedToken: String?

  init(credentials: any CredentialStore) {
    self.credentials = credentials
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    let root = NSView()
    root.translatesAutoresizingMaskIntoConstraints = false

    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.translatesAutoresizingMaskIntoConstraints = false

    progress.style = .spinning
    progress.controlSize = .small
    progress.isDisplayedWhenStopped = false
    progress.translatesAutoresizingMaskIntoConstraints = false

    messageHandler = TokenMessageHandler { [weak self] token in
      self?.received(token: token)
    }

    let contentController = WKUserContentController()
    contentController.add(messageHandler, name: "discordToken")
    contentController.addUserScript(
      WKUserScript(
        source: Self.tokenCaptureScript,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
      )
    )

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController = contentController
    webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.translatesAutoresizingMaskIntoConstraints = false

    root.addSubview(statusLabel)
    root.addSubview(progress)
    root.addSubview(webView)
    NSLayoutConstraint.activate([
      statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      statusLabel.centerYAnchor.constraint(equalTo: progress.centerYAnchor),
      progress.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 10),
      progress.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
      progress.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
      webView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
      webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    self.view = root

    guard let url = URL(string: "https://discord.com/login") else {
      setStatus("Could not construct the Discord login URL.", isError: true)
      return
    }
    let navigation = webView.load(URLRequest(url: url))
    if navigation == nil {
      setStatus("WebKit did not start the Discord login navigation.", isError: true)
    } else {
      setStatus("Opening Discord login…", isError: false)
    }
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    let allowed = url.scheme == "https" || url.scheme == "about"
    decisionHandler(allowed ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    setStatus("Loading Discord login…", isError: false)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    setStatus(
      "Discord login loaded. Sign in and complete 2FA or any challenge here.", isError: false)
    Task { [weak self, weak webView] in
      try? await Task.sleep(for: .seconds(2))
      guard let self, let webView, tokenBeingValidated == nil else { return }
      do {
        let result = try await webView.evaluateJavaScript(
          "({ state: document.readyState, text: (document.body?.innerText || '').trim(), htmlLength: document.documentElement?.outerHTML.length || 0 })"
        )
        guard let values = result as? [String: Any],
          let text = values["text"] as? String,
          text.isEmpty
        else {
          return
        }
        let state = values["state"] as? String ?? "unknown"
        let htmlLength = values["htmlLength"] as? Int ?? 0
        setStatus(
          "Discord returned an empty login page (state \(state), HTML \(htmlLength) bytes).",
          isError: true
        )
      } catch {
        setStatus(
          "Could not inspect the Discord login page: \(error.localizedDescription)", isError: true)
      }
    }
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    setStatus("Discord login failed to load: \(error.localizedDescription)", isError: true)
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: any Error
  ) {
    setStatus("Discord login navigation failed: \(error.localizedDescription)", isError: true)
  }

  private func received(token: String) {
    let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > 20,
      normalized != tokenBeingValidated,
      normalized != rejectedToken
    else {
      return
    }

    tokenBeingValidated = normalized
    progress.startAnimation(nil)
    setStatus("Validating the Discord session…", isError: false)

    Task { [weak self] in
      guard let self else { return }
      do {
        let user = try await DiscordRESTClient(token: normalized).currentUser()
        try credentials.saveToken(normalized)
        progress.stopAnimation(nil)
        setStatus(
          "Signed in as \(user.displayName). The session is stored in Keychain.", isError: false)
        try? await Task.sleep(for: .seconds(1.2))
        NSApplication.shared.terminate(nil)
      } catch {
        rejectedToken = normalized
        tokenBeingValidated = nil
        progress.stopAnimation(nil)
        setStatus("Login could not be validated: \(error.localizedDescription)", isError: true)
      }
    }
  }

  private func setStatus(_ message: String, isError: Bool) {
    statusLabel.stringValue = message
    statusLabel.textColor = isError ? .systemRed : .labelColor
  }

  private static let tokenCaptureScript = """
    (() => {
      let lastToken = null;
      const emit = (raw) => {
        if (typeof raw !== "string" || raw.length === 0) return;
        let token = raw;
        try {
          const decoded = JSON.parse(raw);
          if (typeof decoded === "string") token = decoded;
        } catch (_) {}
        if (typeof token !== "string" || token.length < 20 || token === lastToken) return;
        lastToken = token;
        window.webkit.messageHandlers.discordToken.postMessage(token);
      };

      const originalSetItem = Storage.prototype.setItem;
      Storage.prototype.setItem = function(key, value) {
        const result = originalSetItem.apply(this, arguments);
        if (key === "token") emit(value);
        return result;
      };

      const inspect = () => {
        try { emit(window.localStorage.getItem("token")); } catch (_) {}
      };
      window.addEventListener("storage", (event) => {
        if (event.key === "token") emit(event.newValue);
      });
      window.setInterval(inspect, 500);
      inspect();
    })();
    """
}

@MainActor
private final class TokenMessageHandler: NSObject, WKScriptMessageHandler {
  private let callback: (String) -> Void

  init(callback: @escaping (String) -> Void) {
    self.callback = callback
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let token = message.body as? String else { return }
    callback(token)
  }
}
