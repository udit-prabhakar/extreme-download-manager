"use strict";
const api = globalThis.browser || globalThis.chrome;
const status = document.getElementById("status");
let pageURL = "";
let pageTitle = "";
async function initialize() {
  const settings = await api.storage.local.get(["excludedHosts", "lastStatus"]);
  document.getElementById("excluded").value = settings.excludedHosts || "";
  status.textContent = settings.lastStatus || "";
  const [tab] = await api.tabs.query({active: true, currentWindow: true});
  pageURL = tab?.url || ""; pageTitle = tab?.title || "";
  try { EDM.parseLink(pageURL); document.getElementById("url").value = pageURL; } catch { /* Browser pages cannot be downloads. */ }
}
document.getElementById("send-form").addEventListener("submit", async event => {
  event.preventDefault();
  const button = document.getElementById("send"); button.disabled = true;
  try {
    const result = await EDM.send(api, document.getElementById("url").value.trim(), pageTitle, pageURL);
    status.textContent = result.openAppManually ? "Link queued. Open the app and review Browser links." : "Link queued. Review Browser links in the app.";
    await api.storage.local.remove("lastStatus"); await api.action.setBadgeText({text: ""});
  } catch (error) { status.textContent = error.message; }
  finally { button.disabled = false; }
});
document.getElementById("save").addEventListener("click", async () => {
  try {
    const hosts = EDM.exclusions(document.getElementById("excluded").value);
    await api.storage.local.set({excludedHosts: hosts.join(", ")});
    document.getElementById("excluded").value = hosts.join(", "); status.textContent = "Exclusions saved on this browser.";
  } catch (error) { status.textContent = error.message; }
});
initialize().catch(() => { status.textContent = "Paste a download link to continue."; });
