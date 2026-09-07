// Relays now-playing reports from the content script to the BlueLyrics server.
// Runs in the extension origin so the https page never talks to http itself.
const SERVER = 'http://127.0.0.1:7331/report';

const TOKENS = 'http://127.0.0.1:7331/apple-token';
const CAPTION = 'http://127.0.0.1:7331/caption';

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message) return false;
  if (message.type === 'apple-tokens') {
    fetch(TOKENS, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(message.payload) })
      .then(r => sendResponse({ ok: r.ok })).catch(() => sendResponse({ ok: false }));
    return true;
  }
  if (message.type === 'caption') {
    fetch(CAPTION, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(message.payload) })
      .then(r => sendResponse({ ok: r.ok })).catch(() => sendResponse({ ok: false }));
    return true;
  }
  if (message.type !== 'nowplaying') return false;
  fetch(SERVER, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(message.payload),
  }).then(r => sendResponse({ ok: r.ok })).catch(() => sendResponse({ ok: false }));
  return true;
});
