const $ = (id) => document.getElementById(id);

  async function refresh() {
      const state = await browser.runtime.sendMessage({ fromPopup: "getState" });
      if (!state) return;
      let pretty = "—";
      if (state.event === "init") pretty = "no events yet";
      else if (state.paused === true)  pretty = "Paused";
      else if (state.paused === false) pretty = "Playing";
      else if (state.event === "found") pretty = "found, state unknown";
      $("status").textContent = pretty;
      $("frame").textContent = state.href || "—";
      $("src").textContent = state.src || "";
  }

  $("toggle").addEventListener("click", async () => {
      await browser.runtime.sendMessage({ fromPopup: "toggle" });
      setTimeout(refresh, 200);
  });

  refresh();
  setInterval(refresh, 1000);
