"use strict";
const $ = id => document.getElementById(id);
let activeApp = "", appsSignature = "", busy = false, saving = false, version = 0, mode = "requests";

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
  $("deleteRecords").disabled = saving || !activeApp;
  $("status").textContent = data.connected ? "● 设备已连接" : "等待设备连接";
  $("error").hidden = !data.error || data.error === "正在连接设备";
  $("error").textContent = data.error ? "设备读取未完成：" + data.error : "";
  const items = mode === "domains" ? data.domains : data.requests;
  const rows = items.map(request => {
    const row = document.createElement("tr");
    const urlCell = document.createElement("td"), url = document.createElement("span");
    url.className = "url";
    url.textContent = mode === "domains" ? request.domain : request.url;
    url.title = url.textContent;
    urlCell.append(url);
    const size = document.createElement("td");
    size.className = "size" + (request.size === null ? " unknown" : "");
    size.textContent = sizeLabel(request.size);
    if (request.size !== null) size.title = request.size + " 字节";
    if (mode === "domains") {
      if (request.unknown && request.size !== null) size.textContent = "≥ " + size.textContent;
      size.title = request.requests + " 条请求，其中 " + request.unknown + " 条大小未知" +
        (request.size === null ? "" : "；已知合计 " + request.size + " 字节");
    }
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
    const data = await api("/api/requests?" + new URLSearchParams({app: activeApp, view: mode}));
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

function changeView(next) {
  if (mode === next) return;
  mode = next;
  ++version;
  $("requestsView").setAttribute("aria-pressed", String(mode === "requests"));
  $("domainsView").setAttribute("aria-pressed", String(mode === "domains"));
  $("firstColumn").textContent = mode === "domains" ? "域名" : "请求 URL";
  $("sizeColumn").textContent = mode === "domains" ? "总大小 ↓" : "大小 ↓";
  $("footnote").textContent = mode === "domains"
    ? "汇总当前应用全部已保存请求，按大小降序显示最多 200 个域名。≥ 表示还有大小未知的请求，数值仅为已知合计。"
    : "最近 200 条请求，按大小降序排列，未知最后显示。大小为请求与响应应用数据合计；URL 参数值已脱敏，悬停查看完整 URL。";
  $("requestRows").replaceChildren();
  $("empty").hidden = false;
  $("empty").textContent = "正在加载…";
  refresh();
}
$("requestsView").onclick = () => changeView("requests");
$("domainsView").onclick = () => changeView("domains");
$("deleteRecords").onclick = async () => {
  if (!activeApp || saving) return;
  const name = $("appSelect").selectedOptions[0]?.textContent || activeApp;
  if (!confirm("删除当前应用「" + name + "」的全部监控记录？此操作不可恢复，不影响其他应用。新的请求仍会继续记录。")) return;
  const app = activeApp;
  ++version;
  saving = true;
  $("appSelect").disabled = true;
  $("deleteRecords").disabled = true;
  try {
    const result = await api("/api/clear-app", {app, confirm: "CLEAR"});
    $("hint").textContent = result.message;
  } catch (error) { $("hint").textContent = "删除失败：" + error.message; }
  finally {
    saving = false;
    $("appSelect").disabled = false;
    $("deleteRecords").disabled = false;
    await refresh();
  }
};
refresh();
setInterval(refresh, 1000);
