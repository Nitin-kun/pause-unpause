const statusEl = document.getElementById("status");
const hintEl = document.getElementById("hint");
const syncEl = document.getElementById("sync");

function showStatus(text) {
  statusEl.hidden = !text;
  statusEl.textContent = text || "";
}

function titleFor(info) {
  if (!info) return "No tab assigned";
  return info.title || info.url || "Untitled tab";
}

function paintRole(role, info) {
  const card = document.querySelector(`[data-role="${role}"]`);
  const title = card.querySelector("[data-title]");
  const clear = card.querySelector("[data-clear]");
  title.textContent = titleFor(info);
  title.classList.toggle("is-empty", !info);
  card.classList.toggle("is-set", Boolean(info));
  clear.hidden = !info;
}

function paint(state) {
  paintRole("learning", state.learning);
  paintRole("beat", state.beat);
  syncEl.checked = state.syncEnabled !== false;

  if (state.beatBlocked) {
    hintEl.textContent =
      "The browser blocked autoplay. Click play once on the type beat tab — pause-unpause can take it from there.";
    return;
  }

  if (state.learning && state.beat && state.syncEnabled) {
    hintEl.textContent = state.learningPlaying
      ? "Lecture is playing. Type beat is holding."
      : "Lecture is paused. Type beat should be filling the silence.";
    return;
  }

  hintEl.textContent =
    "Start the type beat once yourself. After that, pause-unpause can pause and resume it.";
}

async function send(message) {
  return chrome.runtime.sendMessage(message);
}

async function refresh() {
  const reply = await send({ type: "GET_STATE" });
  if (reply?.state) paint(reply.state);
}

async function currentTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

document.querySelectorAll("[data-assign]").forEach((button) => {
  button.addEventListener("click", async () => {
    showStatus("");
    const tab = await currentTab();
    if (!tab?.id) {
      showStatus("Couldn't find the current tab.");
      return;
    }
    const reply = await send({ type: "ASSIGN", role: button.dataset.assign, tabId: tab.id });
    if (!reply?.ok) {
      showStatus(reply?.error || "Couldn't assign this tab.");
      return;
    }
    paint(reply.state);
  });
});

document.querySelectorAll("[data-clear]").forEach((button) => {
  button.addEventListener("click", async () => {
    showStatus("");
    const reply = await send({ type: "CLEAR", role: button.dataset.clear });
    if (reply?.state) paint(reply.state);
  });
});

syncEl.addEventListener("change", async () => {
  const reply = await send({ type: "SET_SYNC", enabled: syncEl.checked });
  if (reply?.state) paint(reply.state);
});

refresh();
