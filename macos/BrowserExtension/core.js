/* Shared, dependency-free extension logic; no page scripts or network requests. */
(function (root) {
  "use strict";
  const HOST = "app.extreme.downloadmanager";
  function parseLink(value) {
    if (typeof value !== "string" || new TextEncoder().encode(value).length > 8192 || /[\u0000-\u0020\u007f]/.test(value)) throw new Error("Enter a valid download link without spaces or control characters.");
    let url;
    try { url = new URL(value); } catch { throw new Error("Enter an HTTP, HTTPS, or magnet link."); }
    if (!["http:", "https:", "magnet:"].includes(url.protocol) || url.username || url.password ||
        (url.protocol === "magnet:" ? !url.searchParams.getAll("xt").some(x => x.startsWith("urn:btih:")) : !url.hostname)) throw new Error("Use an HTTP, HTTPS, or BitTorrent magnet link without embedded credentials.");
    return url;
  }
  function exclusions(value) {
    if (typeof value !== "string" || value.length > 4096) throw new Error("Keep the exclusion list under 4096 characters.");
    return [...new Set(value.split(/[\s,]+/).filter(Boolean).map(host => {
      const cleaned = host.toLowerCase().replace(/\.$/, "");
      if (!/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(cleaned) || cleaned.includes("..")) throw new Error("Use host names such as example.com, without paths or wildcards.");
      return cleaned;
    }))];
  }
  function blocked(source, hosts) {
    let host;
    try { host = new URL(source).hostname.toLowerCase().replace(/\.$/, ""); } catch { return false; }
    return hosts.some(value => host === value || host.endsWith("." + value));
  }
  async function send(api, url, title = "", pageURL = "") {
    parseLink(url);
    const settings = await api.storage.local.get("excludedHosts");
    const hosts = exclusions(typeof settings.excludedHosts === "string" ? settings.excludedHosts : "");
    if (blocked(url, hosts) || blocked(pageURL, hosts)) throw new Error("This site is excluded. Edit excluded hosts in the extension popup to send its links.");
    let response;
    try { response = await api.runtime.sendNativeMessage(HOST, {version: 1, action: "handoff", url, title: String(title).slice(0, 200)}); }
    catch { throw new Error("The app bridge is unavailable. Open Extreme Download Manager → Browser links → Browser setup, register the bridge, then try again."); }
    if (!response?.ok) throw new Error(response?.error || "The app could not accept this link.");
    return response;
  }
  const core = Object.freeze({HOST, parseLink, exclusions, blocked, send});
  root.EDM = core;
  if (typeof module !== "undefined") module.exports = core;
})(globalThis);
