// Reads the playing video on YouTube / YouTube Music and reports it to LyricGlow.
// Title/artist come from the Media Session metadata the site itself publishes;
// position and duration come straight from the <video> element.
(() => {
  const isMusic = location.hostname === 'music.youtube.com';
  let lastKey = '';
  let lastSent = 0;

  function videoId() {
    const id = new URLSearchParams(location.search).get('v');
    if (id) return id;
    const match = location.pathname.match(/\/(?:shorts|embed)\/([\w-]+)/);
    return match ? match[1] : location.pathname;
  }

  function metadata(video) {
    const session = navigator.mediaSession?.metadata;
    let title = session?.title || '';
    let artist = session?.artist || '';
    const album = session?.album || '';
    let art = '';
    const artwork = session?.artwork || [];
    if (artwork.length) art = artwork[artwork.length - 1].src || '';
    if (!title) {
      if (isMusic) {
        title = document.querySelector('ytmusic-player-bar .title')?.textContent?.trim() || '';
        artist = document.querySelector('ytmusic-player-bar .byline a')?.textContent?.trim() || '';
      } else {
        title = document.title.replace(/\s*-\s*YouTube$/, '').replace(/^\(\d+\)\s*/, '').trim();
        artist = document.querySelector('ytd-video-owner-renderer #channel-name a, #owner #channel-name a')?.textContent?.trim() || '';
      }
    }
    if (!art && !isMusic) art = `https://i.ytimg.com/vi/${videoId()}/hqdefault.jpg`;
    return { title, artist, album, art };
  }

  function tick() {
    const video = document.querySelector('video');
    if (!video || !Number.isFinite(video.duration) || video.duration === 0) return;
    const meta = metadata(video);
    if (!meta.title) return;
    const status = video.paused || video.ended ? 'paused' : 'playing';
    const key = `${videoId()}|${meta.title}|${status}`;
    const now = Date.now();
    const interval = status === 'playing' ? 250 : 2000;
    if (key === lastKey && now - lastSent < interval) return;
    lastKey = key;
    lastSent = now;
    chrome.runtime.sendMessage({
      type: 'nowplaying',
      payload: {
        source: isMusic ? 'youtube-music' : 'youtube',
        id: videoId(),
        title: meta.title,
        artist: meta.artist,
        album: meta.album,
        art: meta.art,
        duration: video.duration,
        position: video.currentTime,
        status,
      },
    }, () => void chrome.runtime.lastError);
  }

  setInterval(tick, 250);
})();
