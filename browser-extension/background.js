const KEY = "unpause";

const empty = {
  learningTabId: null,
  beatTabId: null,
  syncEnabled: true,
  learningPlaying: false,
  beatBlocked: false,
};

const store = chrome.storage.session ?? chrome.storage.local;

let lastSignal = { type: null, at: 0 };

async function getState() {
  const data = await store.get(KEY);
  return { ...empty, ...data[KEY] };
}

async function setState(patch) {
  const next = { ...(await getState()), ...patch };
  await store.set({ [KEY]: next });
  return next;
}

function tabInfo(tab) {
  if (!tab) return null;
  return {
    id: tab.id,
    title: tab.title || "Untitled",
    url: tab.url || "",
    favIconUrl: tab.favIconUrl || "",
  };
}

async function readTab(id) {
  if (!id) return null;
  try {
    return tabInfo(await chrome.tabs.get(id));
  } catch {
    return null;
  }
}

async function publicState() {
  const state = await getState();
  const learning = await readTab(state.learningTabId);
  const beat = await readTab(state.beatTabId);
  const patch = {};
  if (state.learningTabId && !learning) patch.learningTabId = null;
  if (state.beatTabId && !beat) patch.beatTabId = null;
  if (Object.keys(patch).length) Object.assign(state, await setState(patch));
  return { ...state, learning, beat };
}

function restrictedUrl(url) {
  if (!url) return true;
  return /^(chrome|edge|about|chrome-extension|moz-extension):/i.test(url);
}

async function inject(tabId) {
  try {
    await chrome.scripting.executeScript({
      target: { tabId, allFrames: true },
      files: ["content.js"],
    });
  } catch {
    return false;
  }

  const state = await getState();
  const role =
    tabId === state.learningTabId ? "learning" : tabId === state.beatTabId ? "beat" : null;

  try {
    await chrome.tabs.sendMessage(tabId, { type: "SET_ROLE", role });
  } catch {
    return false;
  }

  if (tabId === state.beatTabId) {
    try {
      await chrome.tabs.update(tabId, { autoDiscardable: false });
    } catch {
      // some browsers ignore this
    }
  }
  return true;
}

async function runInTab(tabId, func, args = []) {
  try {
    return await chrome.scripting.executeScript({
      target: { tabId, allFrames: true },
      func,
      args,
    });
  } catch {
    if (await inject(tabId)) {
      return chrome.scripting.executeScript({
        target: { tabId, allFrames: true },
        func,
        args,
      });
    }
    return [];
  }
}

async function controlBeat(action) {
  const { beatTabId, syncEnabled } = await getState();
  if (!beatTabId || !syncEnabled) return;
  const results = await runInTab(
    beatTabId,
    (nextAction) => window.__unpauseControl?.(nextAction === "play"),
    [action]
  );
  const blocked = (results || []).some((entry) => entry.result && entry.result.reason === "blocked");
  if (blocked) await setState({ beatBlocked: true });
}

async function isTabPlaying(tabId) {
  const results = await runInTab(tabId, () => window.__unpausePlaying?.() ?? false);
  return (results || []).some((entry) => entry.result === true);
}

function freshSignal(type) {
  const now = Date.now();
  if (lastSignal.type === type && now - lastSignal.at < 200) return false;
  lastSignal = { type, at: now };
  return true;
}

async function setBadge(mode) {
  const map = {
    lecture: { text: "▶", color: "#c4d4a8" },
    beat: { text: "♪", color: "#e8a54b" },
    off: { text: "", color: "#8a7d6b" },
  };
  const { text, color } = map[mode] || map.off;
  await chrome.action.setBadgeText({ text });
  await chrome.action.setBadgeBackgroundColor({ color });
}

async function syncFromLearning(playing) {
  const state = await getState();
  if (!state.syncEnabled || !state.learningTabId || !state.beatTabId) return;
  if (!freshSignal(playing ? "play" : "pause")) return;
  await setState({ learningPlaying: playing, beatBlocked: false });
  await controlBeat(playing ? "pause" : "play");
  await setBadge(playing ? "lecture" : "beat");
}

async function queryLearning() {
  const { learningTabId } = await getState();
  if (!learningTabId) return;
  const playing = await isTabPlaying(learningTabId);
  if (typeof playing === "boolean") await syncFromLearning(playing);
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  handle(message, sender).then(sendResponse).catch((err) => {
    sendResponse({ ok: false, error: String(err) });
  });
  return true;
});

async function handle(message, sender) {
  switch (message.type) {
    case "GET_STATE":
      return { ok: true, state: await publicState() };

    case "ASSIGN": {
      const tabId = message.tabId;
      const role = message.role;
      if (!tabId || (role !== "learning" && role !== "beat")) {
        return { ok: false, error: "Pick a tab first." };
      }
      const tab = await readTab(tabId);
      if (!tab) return { ok: false, error: "That tab is gone." };
      if (restrictedUrl(tab.url)) {
        return { ok: false, error: "This page can't be controlled. Open your lecture or beat in a normal tab." };
      }

      const state = await getState();
      const patch = { beatBlocked: false };
      if (role === "learning") {
        if (state.beatTabId === tabId) patch.beatTabId = null;
        patch.learningTabId = tabId;
      } else {
        if (state.learningTabId === tabId) patch.learningTabId = null;
        patch.beatTabId = tabId;
      }
      await setState(patch);
      const injected = await inject(tabId);
      if (!injected) {
        return { ok: false, error: "Couldn't reach this page. Reload it, then try again." };
      }
      await queryLearning();
      return { ok: true, state: await publicState() };
    }

    case "CLEAR": {
      const role = message.role;
      if (role === "learning") await setState({ learningTabId: null, learningPlaying: false });
      else if (role === "beat") await setState({ beatTabId: null, beatBlocked: false });
      else await setState({ ...empty });
      await setBadge("off");
      return { ok: true, state: await publicState() };
    }

    case "SET_SYNC": {
      const enabled = Boolean(message.enabled);
      await setState({ syncEnabled: enabled });
      if (enabled) await queryLearning();
      else await setBadge("off");
      return { ok: true, state: await publicState() };
    }

    case "LEARNING_PLAYING":
      if (sender.tab?.id && sender.tab.id === (await getState()).learningTabId) {
        await syncFromLearning(true);
      }
      return { ok: true };

    case "LEARNING_PAUSED":
      if (sender.tab?.id && sender.tab.id === (await getState()).learningTabId) {
        await syncFromLearning(false);
      }
      return { ok: true };

    case "BEAT_PLAY_BLOCKED":
      await setState({ beatBlocked: true });
      return { ok: true };

    default:
      return { ok: false, error: "Unknown message" };
  }
}

chrome.tabs.onUpdated.addListener(async (tabId, info) => {
  if (info.status !== "complete") return;
  const state = await getState();
  if (tabId === state.learningTabId || tabId === state.beatTabId) {
    await inject(tabId);
    if (tabId === state.learningTabId) await queryLearning();
  }
});

chrome.tabs.onRemoved.addListener(async (tabId) => {
  const state = await getState();
  const patch = {};
  if (state.learningTabId === tabId) {
    patch.learningTabId = null;
    patch.learningPlaying = false;
  }
  if (state.beatTabId === tabId) {
    patch.beatTabId = null;
    patch.beatBlocked = false;
  }
  if (Object.keys(patch).length) {
    await setState(patch);
    await setBadge("off");
  }
});
