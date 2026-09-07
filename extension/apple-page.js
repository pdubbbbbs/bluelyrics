// Runs inside the music.apple.com page itself and reads the MusicKit tokens
// that the site is already using for your logged-in session.
(() => {
  function grab() {
    try {
      const kit = window.MusicKit && window.MusicKit.getInstance && window.MusicKit.getInstance();
      if (!kit || !kit.musicUserToken) return false;
      window.postMessage({
        type: 'lyricglow-apple-tokens',
        developerToken: kit.developerToken || '',
        musicUserToken: kit.musicUserToken,
        storefront: kit.storefrontId || (kit.api && kit.api.storefrontId) || 'us',
      }, 'https://music.apple.com');
      return true;
    } catch (e) { return false; }
  }
  let tries = 0;
  const timer = setInterval(() => { if (grab() || ++tries > 60) clearInterval(timer); }, 1000);
})();
