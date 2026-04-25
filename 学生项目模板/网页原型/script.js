const startBtn = document.getElementById("startBtn");
const resetBtn = document.getElementById("resetBtn");
const statusText = document.getElementById("statusText");
const gamePrompt = document.getElementById("gamePrompt");

startBtn.addEventListener("click", () => {
  statusText.textContent = "试玩中";
  gamePrompt.textContent = "请根据你的创意，把这里改成可以操作的核心玩法。";
});

resetBtn.addEventListener("click", () => {
  statusText.textContent = "未开始";
  gamePrompt.textContent = "请把这里改成你的核心玩法区域。";
});

