// BlueLyrics reporter: reads the playing track from the page's Media Session
// and media element, mirrors the service's own lyrics or captions when it
// shows them, and sends both to the local BlueLyrics window.
(() => {
  const host = location.hostname;
  const SITE = (
    host === 'music.youtube.com' ? { source: 'youtube-music', lyricsLines: 'ytmusic-description-shelf-renderer yt-formatted-string.description, ytmusic-description-shelf-renderer .non-expandable', activeLine: '.blyrics-container .blyrics--active, ytmusic-lyrics-renderer [aria-current], .lyric-line.active' } :
    host === 'www.youtube.com' ? { source: 'youtube', caption: '.ytp-caption-window-container .ytp-caption-segment, .caption-window .captions-text' } :
    host === 'music.amazon.com' ? { source: 'amazon-music', activeLine: '.lyricsContainer .lyric.active, music-lyrics-line[active], .lyrics-line.active, [class*="lyric"][class*="active"]', lyricsLines: '.lyricsContainer .lyric, music-lyrics-line, .lyrics-line' } :
    host === 'www.pandora.com' ? { source: 'pandora', activeLine: '.Lyrics__line--active, .Lyrics__activeLine, [class*="Lyrics"][class*="active"]', lyricsLines: '.Lyrics__line, [class*="Lyrics__line"]' } :
    host === 'open.spotify.com' ? { source: 'spotify', activeLine: '[data-testid="fullscreen-lyric"][class*="active"], [data-testid="fullscreen-lyric"].active, .lyrics-lyricsContent-highlight', lyricsLines: '[data-testid="fullscreen-lyric"]' } :
    host === 'www.netflix.com' ? { source: 'netflix', caption: '.player-timedtext-text-container span, .player-timedtext' } :
    /primevideo|amazon\.com/.test(host) ? { source: 'prime-video', caption: '.atvwebplayersdk-captions-text, [class*="captions"] span' } :
    { source: host, caption: '' });

  let lastKey = '', lastSent = 0, lastCaption = '', lastLyricsKey = '';

  const send = (type, payload) => chrome.runtime.sendMessage({ type, payload }, () => void chrome.runtime.lastError);
  const media = () => [...document.querySelectorAll('video, audio')].find(m => !m.paused && m.readyState > 0) || document.querySelector('video, audio');

  function trackId() {
    const id = new URLSearchParams(location.search).get('v') || new URLSearchParams(location.search).get('trackAsin');
    if (id) return id;
    const m = location.pathname.match(/\/(?:shorts|embed|track|watch|artist|album)\/([\w-]+)/);
    return m ? m[1] : (navigator.mediaSession?.metadata?.title || location.pathname);
  }

  function metadata() {
    const s = navigator.mediaSession?.metadata;
    let title = s?.title || '', artist = s?.artist || '', album = s?.album || '';
    const artwork = s?.artwork || [];
    let art = artwork.length ? artwork[artwork.length - 1].src || '' : '';
    if (!title) {
      if (SITE.source === 'youtube') { title = document.title.replace(/\s*-\s*YouTube$/, '').replace(/^\(\d+\)\s*/, '').trim(); artist = document.querySelector('ytd-video-owner-renderer #channel-name a, #owner #channel-name a')?.textContent?.trim() || ''; }
      else if (SITE.source === 'youtube-music') { title = document.querySelector('ytmusic-player-bar .title')?.textContent?.trim() || ''; artist = document.querySelector('ytmusic-player-bar .byline a')?.textContent?.trim() || ''; }
      else { title = document.title.replace(/\s*[|\-–]\s*(YouTube Music|Amazon Music|Pandora|Spotify|Netflix|Prime Video).*$/i, '').trim(); }
    }
    if (!art && SITE.source === 'youtube') art = `https://i.ytimg.com/vi/${trackId()}/hqdefault.jpg`;
    return { title, artist, album, art };
  }

  /// The service's own lyric lines, when a lyrics panel is open (unsynced unless it exposes timing).
  function nativeLyrics() {
    if (!SITE.lyricsLines) return genericLyrics();
    const nodes = [...document.querySelectorAll(SITE.lyricsLines)];
    if (!nodes.length) return genericLyrics();
    const lines = nodes.length === 1 ? nodes[0].innerText.split('\n') : nodes.map(n => n.innerText);
    const clean = lines.map(l => l.trim()).filter(l => l.length);
    return clean.length >= 4 ? clean : genericLyrics();
  }

  function tick() {
    const m = media();
    if (!m || !Number.isFinite(m.duration) || m.duration === 0) return;
    const meta = metadata();
    if (!meta.title) return;
    if (/^video ad$/i.test(meta.title) || document.querySelector('.ad-showing, .ad-interrupting')) return;
    const status = m.paused || m.ended ? 'paused' : 'playing';
    const key = `${trackId()}|${meta.title}|${status}`;
    const now = Date.now();
    const interval = status === 'playing' ? 250 : 2000;
    if (key !== lastKey || now - lastSent >= interval) {
      lastKey = key; lastSent = now;
      const payload = { source: SITE.source, id: trackId(), title: meta.title, artist: meta.artist, album: meta.album, art: meta.art, duration: m.duration, position: m.currentTime, status };
      const lyrics = nativeLyrics();
      if (lyrics) { const lk = trackId() + '|' + lyrics.length; if (lk !== lastLyricsKey) { lastLyricsKey = lk; payload.lines = lyrics; } }
      send('nowplaying', payload);
    }
  }

  /// Generic fallback: any lyric/caption container whose child is marked active/current/highlighted.
  const PANEL = '[class*="lyric" i], [class*="caption" i], [class*="subtitle" i], [class*="timedtext" i], [id*="lyric" i]';
  const ACTIVE = '[class*="active" i], [class*="current" i], [class*="highlight" i], [class*="playing" i], [aria-current]';
  const looksLikeText = s => s && s.length < 240 && !/^\s*\d+:\d+/.test(s) && /[a-zA-Z\u00C0-\u024F\u0400-\u04FF\u3040-\u30FF\u4E00-\u9FFF]/.test(s);
  const inControls = el => !!el.closest('button, [class*="control" i], [class*="chrome" i], [role="toolbar"], nav, header');
  function genericActive() {
    if (SITE.caption || SITE.activeLine) return '';        // known sites use their explicit selectors only
    for (const panel of document.querySelectorAll(PANEL)) {
      if (inControls(panel)) continue;
      const hit = [...panel.querySelectorAll(ACTIVE)].filter(n => !inControls(n)).map(n => n.innerText.trim()).filter(looksLikeText);
      if (hit.length) return hit.join(' ');
    }
    // caption overlays have no "active" marker: take the visible text of a small caption/subtitle box
    for (const box of document.querySelectorAll('[class*="caption-segment" i], [class*="captions-text" i], [class*="timedtext-text" i], [class*="subtitle" i] span')) {
      const s = box.innerText.trim(); if (looksLikeText(s) && !inControls(box)) return s;
    }
    return '';
  }
  function genericLyrics() {
    for (const panel of document.querySelectorAll('[class*="lyric" i], [id*="lyric" i]')) {
      const kids = [...panel.children].map(k => k.innerText.trim()).filter(s => s && s.length < 200);
      if (kids.length >= 8) return kids;
    }
    return null;
  }

  /// Mirror the line the service is highlighting right now (synced lyrics or captions).
  function mirror() {
    let text = '';
    if (SITE.activeLine) text = [...document.querySelectorAll(SITE.activeLine)].map(n => n.innerText.trim()).filter(Boolean).join(' ');
    if (!text && SITE.caption) text = [...document.querySelectorAll(SITE.caption)].map(n => n.innerText.trim()).filter(Boolean).join(' ');
    if (!text) text = genericActive();
    text = text.replace(/\s+/g, ' ').trim();
    if (text && text !== lastCaption) { lastCaption = text; send('caption', { text, source: SITE.source, at: Date.now() / 1000 }); }
  }

  // YouTube: pull the caption track the player already has and send it as timed lines.
  let timedFor = '';
  window.addEventListener('message', async e => {
    if (e.source !== window || e.data?.type !== 'bluelyrics-yt-captions' || !e.data.tracks?.length) return;
    if (e.data.videoId === timedFor) return;
    const pick = e.data.tracks.find(t => /^en/.test(t.lang) && t.kind !== 'asr') || e.data.tracks.find(t => /^en/.test(t.lang)) || e.data.tracks[0];
    try {
      const j = await (await fetch(pick.url + '&fmt=json3')).json();
      const lines = (j.events || []).filter(ev => ev.segs && ev.tStartMs != null).map(ev => ({ t: ev.tStartMs / 1000, end: ev.dDurationMs ? (ev.tStartMs + ev.dDurationMs) / 1000 : undefined, text: ev.segs.map(s => s.utf8).join('').replace(/\s+/g, ' ').trim() })).filter(l => l.text && l.text !== '\n');
      if (lines.length >= 3) { timedFor = e.data.videoId; send('nowplaying', { source: SITE.source, id: e.data.videoId, title: metadata().title || document.title, artist: metadata().artist, duration: media()?.duration || 0, position: media()?.currentTime || 0, status: media()?.paused ? 'paused' : 'playing', timedLines: lines, captionLang: pick.lang, captionKind: pick.kind }); }
    } catch (err) { /* no captions for this video */ }
  });

  window.addEventListener('message', async e => {
    if (e.source !== window || e.data?.type !== 'bluelyrics-yt-timedtext' || !e.data.url) return;
    try {
      const url = e.data.url.replace(/([?&])fmt=[^&]*/, '$1fmt=json3') + (/fmt=/.test(e.data.url) ? '' : '&fmt=json3');
      const j = await (await fetch(url)).json();
      const lines = (j.events || []).filter(ev => ev.segs && ev.tStartMs != null).map(ev => ({ t: ev.tStartMs / 1000, end: ev.dDurationMs ? (ev.tStartMs + ev.dDurationMs) / 1000 : undefined, text: ev.segs.map(s => s.utf8).join('').replace(/\s+/g, ' ').trim() })).filter(l => l.text);
      if (lines.length >= 3) { timedFor = e.data.videoId; send('nowplaying', { source: SITE.source, id: e.data.videoId, title: metadata().title || document.title, artist: metadata().artist, duration: media()?.duration || 0, position: media()?.currentTime || 0, status: media()?.paused ? 'paused' : 'playing', timedLines: lines }); }
    } catch (err) { /* ignore */ }
  });

  setInterval(tick, 250);
  setInterval(mirror, 200);
})();
