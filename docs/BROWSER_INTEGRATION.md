# Browser link handoff

This development milestone adds an explicit **Send to Extreme Download Manager** link action and a toolbar popup for Chrome/Edge 123+ and Firefox 140+. It does not intercept normal browser downloads. Safari, store publication, authenticated request handoff, and automatic capture remain future work.

## Setup

1. Build the app with `cd macos && bash scripts/build.sh release`, then keep the full `.app` in a permanent location.
2. Open **Browser links → Browser setup** in the app. Choose your browser and select **Register browser bridge**. This writes one native-messaging manifest for the current macOS user. No administrator permission or listening server is required.
3. Select **Show extension folder**. Each packaged extension is standalone.
4. For Chrome/Edge, open `chrome://extensions` or `edge://extensions`, enable Developer mode, choose **Load unpacked**, and select the `chromium` folder. Its manifest public key gives the development extension a stable ID: `khfkcfjbpjhanmpplpkldiobnkkaoibj`.
5. For Firefox, open `about:debugging`, select **This Firefox → Load Temporary Add-on**, and choose the `firefox/manifest.json` file. The development ID is `browser@extreme.downloadmanager.app`. Temporary Firefox add-ons must be reloaded after Firefox restarts. Signed permanent distribution is not available yet.
6. Pin the extension. Right-click a download link and choose **Send to Extreme Download Manager**, or paste a download URL in the popup. The popup can prefill the current tab URL, which may be a web page rather than a downloadable file.
7. In the app, open **Browser links**, review the URL, choose the destination and optional filename, then choose **Download** or **Add paused**, according to your automatic-start preference. Nothing is downloaded merely by handing off a link. Dismiss removes only that pending link.

Moving the app changes the helper path; register again from its new location. **Remove registration** removes only this app's native host manifest for the selected browser. Remove the extension separately through the browser's extension manager.

## Site exclusions

Open the extension popup, expand **Excluded sites**, and enter comma-separated host names such as `example.com, private.example`. Exclusions cover each exact host and its subdomains. They prevent sending a link if either its destination or the page it came from is excluded. They are stored in that browser's local extension storage, without sync or a remote service.

## Data and permissions

- The extension requests `nativeMessaging`, `contextMenus`, `storage`, and `activeTab`. It has no cookie, history, downloads interception, content-script, or general host permission.
- Only a URL you explicitly send and a short title go to the app. Page URLs used for exclusions remain in the extension. There are no requests to an application vendor server and no telemetry.
- Firefox declares `browsingActivity` and `websiteContent` transmission because selected URLs and titles leave the extension for the local Mac app. This follows [Mozilla's data-transmission taxonomy](https://extensionworkshop.com/documentation/develop/firefox-builtin-data-consent/); it does not mean the extension continuously reads browsing history.
- URLs may contain private query tokens. Pending links are stored locally in `BrowserInbox` inside the app profile, with private folder/file permissions, until reviewed or dismissed. Accepted URLs also appear in normal download history/session data. Do not send links you do not want the app to retain.
- HTTP/HTTPS and BitTorrent magnets are accepted. Embedded username/password URLs, local file URLs, executable URL schemes, control characters, malformed protocol messages, and oversized input are refused.
- The browser starts a short-lived helper through native messaging pipes. The helper checks the calling extension ID, stores a validated request, and wakes the app. It does not expose or forward aria2 RPC, request cookies, or execute supplied commands.
- The inbox holds up to 100 pending links. Review or dismiss links to free space. Inbox records carry stable request IDs so replaying an already accepted request does not create another job.

Native host manifests are registered under the current user's `~/Library/Application Support/Google/Chrome/NativeMessagingHosts`, `Microsoft Edge/NativeMessagingHosts`, or `Mozilla/NativeMessagingHosts`. Other native hosts are left unchanged. The application must remain installed at the registered path.

## Development verification

`bash macos/scripts/test.sh` requires Node.js 20+, Swift, Python 3, and aria2. It runs extension logic tests, real native-host framing tests, and the local transfer suite. Registrations in automated tests use a generated Library fixture; no real browser profiles are modified. The transfer test verifies review-before-download, paused defaults, request deduplication, dismissal, and a correct 24 MiB output.

Use `EDM_DATA_DIR`, `EDM_OFFLINE_TEST=1`, and optionally `EDM_BROWSER_LIBRARY` for isolated native UI checks. `EDM_NATIVE_HOST_NO_LAUNCH=1` suppresses the host's app wake-up during CLI framing tests. None of these flags intercepts browser traffic.

Protocol and registration references: [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [Edge native messaging](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/native-messaging), [Firefox native messaging](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging), and [Firefox native manifests](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_manifests).
