"use strict";
const $ = id => document.getElementById(id);
let activeApp = "", appsSignature = "", busy = false, saving = false, version = 0;

async function api(path, body) {
  const response = await fetch(path, {
    method: body ? "POST" : "GET",
    headers: body ? {"Content-Type": "application/json"} : {},
    body: body ? JSON.stringify(body) : undefined
  });
  const data = await response.json();
  if (!response.ok) throw Error(data.error || "操作失败");
  return data;
}

function sizeLabel(value) {
  if (value === null || !Number.isFinite(value)) return "未知";
  if (value < 1024) return value + " B";
  for (const unit of ["KB", "MB", "GB", "TB"]) {
    value /= 1024;
    if (value < 1024 || unit === "TB") return value.toFixed(value < 10 ? 2 : 1) + " " + unit;
  }
}

function render(data) {
  if (!activeApp) activeApp = data.app || "";
  const signature = JSON.stringify(data.apps);
  if (signature !== appsSignature) {
    appsSignature = signature;
    const choices = data.apps.map(app => new Option(app.name + " · " + app.id, app.id));
    $("appSelect").replaceChildren(new Option("请选择一个应用", ""), ...choices);
  }
  $("appSelect").value = activeApp;
  $("appSelect").disabled = saving || !data.apps.length;
  $("status").textContent = data.connected ? "● 设备已连接" : "等待设备连接";
  $("error").hidden = !data.error || data.error === "正在连接设备";
  $("error").textContent = data.error ? "设备读取未完成：" + data.error : "";
  const rows = data.requests.map(request => {
    const row = document.createElement("tr");
    const urlCell = document.createElement("td"), url = document.createElement("span");
    url.className = "url";
    url.textContent = request.url;
    url.title = request.url;
    urlCell.append(url);
    const size = document.createElement("td");
    size.className = "size" + (request.size === null ? " unknown" : "");
    size.textContent = sizeLabel(request.size);
    if (request.size !== null) size.title = request.size + " 字节";
    row.append(urlCell, size);
    return row;
  });
  $("requestRows").replaceChildren(...rows);
  $("empty").hidden = rows.length > 0;
  $("empty").textContent = activeApp ? "暂无请求，请重新打开所选应用并产生网络活动。" : "请选择需要监控的应用。";
}

async function refresh() {
  if (busy || saving) return;
  busy = true;
  const current = version;
  try {
    const data = await api("/api/requests?" + new URLSearchParams({app: activeApp}));
    if (current === version) render(data);
  } catch (error) {
    if (current === version) {
      $("error").textContent = error.message;
      $("error").hidden = false;
    }
  } finally { busy = false; }
}

$("appSelect").onchange = async () => {
  const chosen = $("appSelect").value;
  if (!chosen || chosen === activeApp) { $("appSelect").value = activeApp; return; }
  const previous = activeApp;
  activeApp = chosen;
  ++version;
  saving = true;
  $("appSelect").disabled = true;
  $("requestRows").replaceChildren();
  $("empty").hidden = false;
  $("empty").textContent = "正在切换监控应用…";
  try {
    await api("/api/config", {selected: [chosen], paused: false});
    $("hint").textContent = "已选择该应用。请完全退出并重新打开该应用，随后请求会自动显示。";
  } catch (error) {
    activeApp = previous;
    $("hint").textContent = "切换失败：" + error.message;
  } finally {
    saving = false;
    $("appSelect").disabled = false;
    await refresh();
  }
};
refresh();
setInterval(refresh, 1000);
