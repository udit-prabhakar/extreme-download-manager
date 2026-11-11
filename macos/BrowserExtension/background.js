"use strict";
if (typeof importScripts === "function" && !globalThis.EDM) importScripts("core.js");
const api = globalThis.browser || globalThis.chrome;
api.runtime.onInstalled.addListener(async () => {
  await api.contextMenus.removeAll();
  api.contextMenus.create({id: "send-extreme", title: "Send to Extreme Download Manager", contexts: ["link"]});
});
api.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId !== "send-extreme") return;
  EDM.send(api, info.linkUrl, info.linkText || tab?.title || "", info.pageUrl || "")
    .then(async response => {
      await api.storage.local.set({lastStatus: response.openAppManually ? "Link queued. Open the app and review Browser links." : "Link queued for review in the app."});
      await api.action.setBadgeText({text: ""});
    }).catch(async error => {
      await api.storage.local.set({lastStatus: error.message});
      await api.action.setBadgeText({text: "!"});
      await api.action.setBadgeBackgroundColor({color: "#a93434"});
    });
});
