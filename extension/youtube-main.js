// Runs in the page's own world on youtube.com to read the caption track list
// the player already has, and hands the URL to the reporter (isolated world).
(() => {
  let lastVideo = '';
  setInterval(() => {
    const id = new URLSearchParams(location.search).get('v');
    if (!id || id === lastVideo) return;
    const r = window.ytInitialPlayerResponse;
    if (!r || r.videoDetails?.videoId !== id) return;
    lastVideo = id;
    const tracks = (r.captions?.playerCaptionsTracklistRenderer?.captionTracks || []).map(t => ({ lang: t.languageCode, kind: t.kind || '', url: t.baseUrl }));
    window.postMessage({ type: 'bluelyrics-yt-captions', videoId: id, tracks }, location.origin);
  }, 1000);
  // When the player itself fetches a caption track (captions turned on), pass that exact URL along: it carries the token the API needs.
  let lastTimed = '';
  setInterval(() => {
    const u = performance.getEntriesByType('resource').map(e => e.name).filter(n => /\/api\/timedtext/.test(n)).pop();
    if (u && u !== lastTimed) { lastTimed = u; window.postMessage({ type: 'bluelyrics-yt-timedtext', videoId: new URLSearchParams(location.search).get('v'), url: u }, location.origin); }
  }, 1500);
})();
