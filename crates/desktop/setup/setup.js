// First run: save the server address; the app then opens a window onto it.
document.getElementById("f").addEventListener("submit", async (e) => {
  e.preventDefault();
  const err = document.getElementById("err");
  err.textContent = "";
  try {
    await window.__TAURI__.core.invoke("connect", { url: document.getElementById("url").value });
  } catch (message) {
    err.textContent = String(message);
  }
});
