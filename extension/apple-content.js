// Injects apple-page.js into music.apple.com and relays the tokens it finds.
(() => {
  const script = document.createElement('script');
  script.src = chrome.runtime.getURL('apple-page.js');
  script.onload = () => script.remove();
  (document.head || document.documentElement).appendChild(script);
  let sent = '';
  window.addEventListener('message', event => {
    if (event.source !== window || !event.data || event.data.type !== 'bluelyrics-apple-tokens') return;
    if (event.data.musicUserToken === sent) return;
    sent = event.data.musicUserToken;
    chrome.runtime.sendMessage({ type: 'apple-tokens', payload: {
      developerToken: event.data.developerToken, musicUserToken: event.data.musicUserToken, storefront: event.data.storefront,
    } }, () => void chrome.runtime.lastError);
  });
})();
