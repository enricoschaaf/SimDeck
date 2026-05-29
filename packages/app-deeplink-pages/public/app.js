const LOCAL_URL = "http://localhost:4310";

(async () => {
  const redirectBtn = document.getElementById("redirect-btn");
  const status = document.getElementById("status");
  const manualHost = document.getElementById("manual-host");
  const manualConnect = document.getElementById("manual-connect");
  const err = document.getElementById("error");

  function show(text) {
    status.textContent = text;
  }

  function setPage(state) {
    document.querySelector(".page").dataset.state = state;
    if (state === "offline") {
      redirectBtn.hidden = true;
    }
  }

  // Probe localhost:4310 with a lightweight HEAD
  try {
    show("Checking for SimDeck on this Mac…");
    const resp = await fetch(`${LOCAL_URL}/api/health`, {
      method: "HEAD",
      mode: "cors",
      cache: "no-store",
    });
    if (resp.ok || resp.status === 401) {
      show(`SimDeck server found — redirecting to ${LOCAL_URL}…`);
      setPage("found");
      location.href = LOCAL_URL;
      return;
    }
    throw new Error(`Unexpected status ${resp.status}`);
  } catch {
    show("SimDeck not running on this Mac");
    setPage("offline");
  }

  redirectBtn.addEventListener("click", () => {
    location.href = LOCAL_URL;
  });

  manualConnect.addEventListener("click", () => {
    const url = manualHost.value.trim();
    if (!url) return;
    const httpUrl = url.startsWith("http") ? url : `http://${url}`;
    try {
      const parsed = new URL(httpUrl);
      location.href = parsed.origin;
    } catch {
      err.hidden = false;
      err.textContent = "Invalid URL. Try something like 10.0.0.55:4310";
    }
  });

  manualHost.addEventListener("keydown", (e) => {
    if (e.key === "Enter") manualConnect.click();
  });
})();
