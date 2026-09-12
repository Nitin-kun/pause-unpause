(() => {
  if (window.__unpauseInstalled) return;
  window.__unpauseInstalled = true;

  let role = null;
  let pauseTimer = 0;
  const bound = new WeakSet();

  function mediaList() {
    return [...document.querySelectorAll("video, audio")].filter((el) => {
      const rect = el.getBoundingClientRect();
      const visible = el.tagName === "AUDIO" || rect.width * rect.height > 0 || el.classList.contains("html5-main-video");
      return visible;
    });
  }

  function primaryMedia() {
    const items = mediaList();
    if (!items.length) return null;
    const playing = items.find((el) => !el.paused && !el.ended && el.readyState > 0);
    if (playing) return playing;
    const yt = document.querySelector("video.html5-main-video");
    if (yt) return yt;
    return items.sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];
  }

  function anyPlaying() {
    return mediaList().some((el) => !el.paused && !el.ended);
  }

  function reportPlaying() {
    if (role !== "learning") return;
    clearTimeout(pauseTimer);
    chrome.runtime.sendMessage({ type: "LEARNING_PLAYING" }).catch(() => {});
  }

  function reportPaused() {
    if (role !== "learning") return;
    clearTimeout(pauseTimer);
    pauseTimer = setTimeout(() => {
      const media = primaryMedia();
      if (media && (media.seeking || !media.paused)) return;
      if (anyPlaying()) return;
      chrome.runtime.sendMessage({ type: "LEARNING_PAUSED" }).catch(() => {});
    }, 280);
  }

  function attach(el) {
    if (bound.has(el)) return;
    bound.add(el);
    el.addEventListener("play", reportPlaying);
    el.addEventListener("playing", reportPlaying);
    el.addEventListener("pause", reportPaused);
    el.addEventListener("ended", reportPaused);
  }

  function scan() {
    mediaList().forEach(attach);
    const yt = document.querySelector("video.html5-main-video");
    if (yt) attach(yt);
  }

  async function clickYoutubeIfNeeded(shouldPlay, media) {
    if (!shouldPlay || !media || !media.paused) return false;
    const btn = document.querySelector(".ytp-play-button, .play-pause-button, [data-testid='play-pause-button']");
    if (!btn) return false;
    const label = (btn.getAttribute("aria-label") || btn.title || "").toLowerCase();
    if (label.includes("pause")) return false;
    btn.click();
    return true;
  }

  async function setPlaying(shouldPlay) {
    scan();
    const media = primaryMedia();
    if (!media) return { ok: false, reason: "no-media" };

    if (shouldPlay) {
      if (!media.paused && !media.ended) return { ok: true };
      try {
        await media.play();
        return { ok: true };
      } catch {
        const clicked = await clickYoutubeIfNeeded(true, media);
        if (clicked && !media.paused) return { ok: true };
        chrome.runtime.sendMessage({ type: "BEAT_PLAY_BLOCKED" }).catch(() => {});
        return { ok: false, reason: "blocked" };
      }
    }

    if (!media.paused) media.pause();
    return { ok: true };
  }

  window.__unpauseControl = setPlaying;
  window.__unpausePlaying = () => {
    scan();
    return anyPlaying();
  };

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message.type === "SET_ROLE") {
      role = message.role;
      scan();
      if (role === "learning" && anyPlaying()) reportPlaying();
      sendResponse({ ok: true, role });
      return;
    }

    if (message.type === "CONTROL") {
      setPlaying(message.action === "play").then((result) => sendResponse(result));
      return true;
    }

    if (message.type === "QUERY_PLAYING") {
      scan();
      sendResponse({ ok: true, playing: anyPlaying() });
    }
  });

  const observer = new MutationObserver(() => scan());
  observer.observe(document.documentElement, { childList: true, subtree: true });
  scan();
})();
