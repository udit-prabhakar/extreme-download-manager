const {test} = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const core = require('../BrowserExtension/core.js');
const source = path.join(__dirname, '../BrowserExtension');

test('only downloadable URLs without embedded credentials are accepted', () => {
  for (const link of ['https://example.test/a?token=fixture', 'http://127.0.0.1/file', 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789']) assert.doesNotThrow(() => core.parseLink(link));
  for (const link of ['file:///tmp/test', 'javascript:alert(1)', 'data:text/plain,hello', 'https://u:p@example.test/a', 'https://example.test/a\nheader', 'magnet:?dn=hello', 'https://example.test/' + 'a'.repeat(8192)]) assert.throws(() => core.parseLink(link));
});
test('exclusions match exact hosts and subdomains without suffix confusion', () => {
  const hosts = core.exclusions('EXAMPLE.com., example.com, work.test');
  assert.deepEqual(hosts, ['example.com', 'work.test']);
  assert.equal(core.blocked('https://sub.example.com/a', hosts), true);
  assert.equal(core.blocked('https://notexample.com/a', hosts), false);
  assert.equal(core.blocked('https://example.com.attacker.test/a', hosts), false);
  assert.throws(() => core.exclusions('https://example.com/path'));
});
test('handoff sends only selected URL/title; excluded pages never contact the host', async () => {
  const sent = [];
  const api = {storage:{local:{get:async()=>({excludedHosts:'private.test'})}},runtime:{sendNativeMessage:async(host, message)=>{sent.push({host,message});return {ok:true,queued:true};}}};
  await assert.rejects(core.send(api, 'https://download.test/file', 'Title', 'https://private.test/page'), /excluded/);
  assert.equal(sent.length, 0);
  await core.send(api, 'https://download.test/file', 'Title', 'https://public.test/page');
  assert.deepEqual(sent, [{host:'app.extreme.downloadmanager',message:{version:1,action:'handoff',url:'https://download.test/file',title:'Title'}}]);
  api.runtime.sendNativeMessage=async()=>{throw new Error('Missing host');};
  await assert.rejects(core.send(api, 'https://download.test/file'), /Browser setup/);
});
test('manifest identity and permission boundary match the native host', () => {
  const chromium = JSON.parse(fs.readFileSync(path.join(source, 'manifests/chromium.json')));
  const digest = crypto.createHash('sha256').update(Buffer.from(chromium.key, 'base64')).digest().subarray(0,16);
  const id = [...digest].map(x=>String.fromCharCode(97+(x>>4),97+(x&15))).join('');
  assert.equal(id, 'khfkcfjbpjhanmpplpkldiobnkkaoibj');
  for (const browser of ['chromium', 'firefox']) {
    const manifest=JSON.parse(fs.readFileSync(path.join(source, 'manifests', browser+'.json')));
    assert.deepEqual(manifest.permissions, ['nativeMessaging','contextMenus','storage','activeTab']);
    assert.equal(manifest.host_permissions, undefined);
    assert.equal(manifest.content_scripts, undefined);
  }
});
test('context menu initialization uses promise APIs and hands off a clicked link', async () => {
  const listeners = {}, menus = [], sent = [];
  const api = {runtime:{onInstalled:{addListener:fn=>listeners.install=fn}},contextMenus:{removeAll:async()=>{},create:value=>menus.push(value),onClicked:{addListener:fn=>listeners.click=fn}},storage:{local:{set:async()=>{}}},action:{setBadgeText:async()=>{},setBadgeBackgroundColor:async()=>{}}};
  vm.runInNewContext(fs.readFileSync(path.join(source, 'background.js'),'utf8'), {chrome:api,EDM:{send:async(...args)=>{sent.push(args);return {ok:true};}}});
  await listeners.install();
  assert.equal(menus[0].id, 'send-extreme');
  listeners.click({menuItemId:'send-extreme',linkUrl:'https://example.test/file',pageUrl:'https://example.test/page'}, {title:'Fixture'});
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(sent[0][1], 'https://example.test/file');
});
