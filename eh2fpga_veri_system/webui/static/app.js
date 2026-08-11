const ui = {
  state: document.getElementById('boardState'), lastCode: document.getElementById('lastCode'),
  captureBadge: document.getElementById('captureBadge'), txBadge: document.getElementById('txBadge'),
  interfaceSelect: document.getElementById('interfaceSelect'), diagnostic: document.getElementById('networkDiagnostic'),
  manifest: document.getElementById('programManifest'), programFile: document.getElementById('programFile'),
  progress: document.getElementById('txProgress'), txOperation: document.getElementById('txOperation'), txCount: document.getElementById('txCount'),
  reductionBody: document.getElementById('reductionBody'), timeline: document.getElementById('eventTimeline'),
  sessionFiles: document.getElementById('sessionFiles'), wawDetails: document.getElementById('wawDetails'), toast: document.getElementById('toast'),
  systemMessageBody: document.getElementById('systemMessageBody'), comparisonSummary: document.getElementById('comparisonSummary'),
  latestReduction: document.getElementById('latestReduction')
};

let uploadId = null;
let latestStatus = null;
let toastTimer = null;

function esc(value) {
  return String(value ?? '').replace(/[&<>'"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
}

async function api(path, options = {}) {
  const response = await fetch(path, options);
  let body = {};
  try { body = await response.json(); } catch (_) { /* empty */ }
  if (!response.ok) throw new Error(body.detail || `${response.status} ${response.statusText}`);
  return body;
}

function notify(message, level = 'info') {
  ui.toast.textContent = message;
  ui.toast.className = `toast show ${level}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => ui.toast.className = 'toast', 4200);
}

async function refreshInterfaces() {
  try {
    const result = await api('/api/interfaces');
    ui.interfaceSelect.innerHTML = result.interfaces.map(item =>
      `<option value="${esc(item.id)}">${esc(item.description || item.name)} | MAC ${esc(item.mac || '未知')} | ${esc(item.ipv4 || '无IPv4')}</option>`
    ).join('');
    if (!result.interfaces.length) ui.interfaceSelect.innerHTML = '<option value="">未发现网卡</option>';
    const d = result.diagnostics;
    ui.diagnostic.textContent = `Scapy ${d.scapy_available ? d.scapy_version : '不可用'}；pcap provider=${d.pcap_provider}。请选择连接FPGA的有线网卡。`;
    if (!d.pcap_provider) ui.diagnostic.textContent += ' 当前未检测到pcap provider，请检查Npcap安装。';
  } catch (error) { notify(error.message, 'error'); ui.diagnostic.textContent = error.message; }
}

async function startCapture() {
  try {
    await api('/api/capture/start', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({interface_id:ui.interfaceSelect.value})});
    notify('持续监听已启动'); await refreshStatus();
  } catch (error) { notify(error.message, 'error'); }
}

async function stopCapture() {
  try { await api('/api/capture/stop', {method:'POST'}); notify('监听已停止', 'warning'); await refreshStatus(); }
  catch (error) { notify(error.message, 'error'); }
}

async function inspectProgram() {
  const file = ui.programFile.files[0];
  if (!file) return notify('请先选择.bin文件', 'warning');
  if (!file.name.toLowerCase().endsWith('.bin')) return notify('只允许原始二进制.bin文件', 'error');
  const form = new FormData(); form.append('file', file);
  try {
    const result = await api('/api/program/inspect', {method:'POST', body:form});
    uploadId = result.manifest.upload_id; renderManifest(result.manifest); notify('程序检查完成');
  } catch (error) { uploadId = null; notify(error.message, 'error'); }
}

function renderManifest(m) {
  const golden = m.sha256.toUpperCase() === '5D073F32602F986E6AE253F425046271C4255402067632DA7C6FFD43E4A1CCFC';
  ui.manifest.className = 'manifest';
  ui.manifest.innerHTML = `
    <div><span>文件</span>${esc(m.filename)}</div><div><span>原始字节</span>${m.program_bytes.toLocaleString()}</div>
    <div><span>程序帧数</span>${m.frame_count.toLocaleString()}</div><div><span>补零字节</span>${m.padding_bytes}</div>
    <div><span>DDR范围</span>${esc(m.base_address)} ～ ${esc(m.last_ddr_address)}</div>
    <div><span>20万条黄金程序</span><b class="${golden?'pass':'warning'}">${golden?'SHA-256匹配':'非基准程序'}</b></div>
    <div style="grid-column:1/-1"><span>SHA-256</span><code>${esc(m.sha256)}</code></div>
    <div style="grid-column:1/-1"><span>前64字节</span><code>${esc(m.preview_hex)}</code></div>`;
}

function sendBody(extra = {}) {
  return JSON.stringify({force:document.getElementById('forceSend').checked, inter_frame_us:Number(document.getElementById('interFrameUs').value || 0), ...extra});
}

async function sendPreconfig() {
  try { await api('/api/preconfig/send', {method:'POST', headers:{'Content-Type':'application/json'}, body:sendBody()}); notify('PRECONFIG检查帧发送任务已启动'); }
  catch (error) { notify(error.message, 'error'); }
}

async function sendProgram() {
  if (!uploadId) return notify('请先载入并检查.bin程序', 'warning');
  if (!confirm('确认发送全部程序帧，并在最后一帧后立即发送结束帧？')) return;
  try { await api('/api/program/send', {method:'POST', headers:{'Content-Type':'application/json'}, body:sendBody({upload_id:uploadId})}); notify('程序发送任务已启动'); }
  catch (error) { notify(error.message, 'error'); }
}

async function sendEndOnly() {
  if (!confirm('单独发送结束帧可能使板卡进入ERROR，确认继续？')) return;
  try { await api('/api/end/send', {method:'POST'}); notify('结束帧已提交', 'warning'); }
  catch (error) { notify(error.message, 'error'); }
}

async function clearLogs() {
  if (!confirm('清理页面和后台内存中的当前日志？磁盘中的历史会话文件会保留。')) return;
  try { await api('/api/logs/clear', {method:'POST'}); notify('当前残留日志已清理'); await refreshStatus(); }
  catch (error) { notify(error.message, 'error'); }
}

async function saveLogs() {
  try {
    const result = await api('/api/logs/save', {method:'POST'});
    notify(`日志已保存：${result.file.name}`); await refreshStatus();
  } catch (error) { notify(error.message, 'error'); }
}

function renderStatus(s) {
  latestStatus = s;
  ui.state.textContent = s.board_state;
  ui.state.className = `state ${String(s.board_state).toLowerCase()}`;
  ui.lastCode.textContent = s.last_system_code ? `最后状态码 0x${s.last_system_code}` : '尚未收到系统信息帧';
  ui.captureBadge.textContent = s.capture_running ? '正在监听' : '未监听';
  ui.captureBadge.className = `pill ${s.capture_running?'live':'idle'}`;
  ui.txBadge.textContent = s.tx_busy ? '发送中' : '发送器空闲'; ui.txBadge.className = `pill ${s.tx_busy?'busy':'idle'}`;
  document.getElementById('sendProgram').disabled = s.tx_busy;
  document.getElementById('rxTotal').textContent = s.stats.rx_total;
  document.getElementById('rxSystem').textContent = s.stats.rx_system;
  document.getElementById('rxLog').textContent = s.stats.rx_log;
  document.getElementById('rxInvalid').textContent = s.stats.rx_invalid;
  document.getElementById('txTotal').textContent = s.stats.tx_total;
  const p = s.tx_progress || {};
  ui.progress.style.width = `${p.percent || 0}%`; ui.txOperation.textContent = p.operation || '无发送任务'; ui.txCount.textContent = `${p.sent || 0} / ${p.total || 0}`;
  renderSystemMessages(s.system_messages || []); renderReductions(s.reductions || []);
  renderComparison(s.comparison_summary || {}); renderEvents(s.events || []); renderSessionFiles(s.session_files || []);
}

function renderSystemMessages(items) {
  if (!items.length) { ui.systemMessageBody.innerHTML = '<tr><td colspan="5" class="empty-cell">尚未收到系统信息</td></tr>'; return; }
  ui.systemMessageBody.innerHTML = [...items].reverse().map(item => `<tr>
    <td>${esc(item.received_at || '')}</td><td><code>0x${esc(item.code)}</code></td>
    <td>${esc(item.name)}</td><td>${esc(item.state)}</td><td>${esc(item.description)}</td></tr>`).join('');
}

function renderReductions(items) {
  if (!items.length) { ui.reductionBody.innerHTML = '<tr><td colspan="12" class="empty-cell">尚未收到日志帧</td></tr>'; return; }
  ui.reductionBody.innerHTML = items.map((r, index) => {
    const result = r.golden?.status || 'NO_GOLDEN'; const cls = result === 'PASS' ? 'pass' : result === 'FAIL' ? 'fail' : 'warning';
    return `<tr class="log-row" data-index="${index}"><td>${esc(r.received_at || '')}</td><td>${r.hart_id}</td><td>${r.package_number}</td><td>${r.count}</td><td>${r.waw_count}</td>
      <td>${esc(r.xor0)}</td><td>${esc(r.xor1)}</td><td>${esc(r.sum0)}</td><td>${esc(r.sum1)}</td><td>${esc(r.sum2)}</td><td>${esc(r.sum3)}</td><td class="${cls}">${result}</td></tr>`;
  }).join('');
  ui.reductionBody.querySelectorAll('tr').forEach(row => row.addEventListener('click', () => {
    const r = items[Number(row.dataset.index)];
    const mismatch = r.golden?.mismatches?.length ? `；不一致：${r.golden.mismatches.join('；')}` : '';
    ui.wawDetails.textContent = `hart${r.hart_id} package${r.package_number}：WAW数量=${r.waw_count}；序号=[${r.waw_sequences.join(', ')}]；帧合法=${r.valid}；黄金=${r.golden?.status}${mismatch}`;
  }));
}

function renderComparison(summary) {
  const status = summary.status || 'WAITING';
  const cls = status === 'PASS' ? 'pass' : status === 'FAIL' ? 'fail' : 'warning';
  ui.comparisonSummary.className = 'manifest';
  ui.comparisonSummary.innerHTML = `<div><span>总体比较</span><b class="${cls}">${esc(status)}</b></div>
    <div><span>接收/期望package</span>${summary.received_packages || 0} / ${summary.expected_packages || 0}</div>
    <div><span>PASS</span>${summary.passed_packages || 0}</div><div><span>FAIL</span>${summary.failed_packages || 0}</div>`;
  const last = summary.last_reduction;
  ui.latestReduction.textContent = last
    ? `最后归约：${last.received_at || ''}；hart${last.hart_id} package${last.package_number}；count=${last.count}；WAW=${last.waw_count}；比较=${last.golden?.status || 'NO_GOLDEN'}`
    : '尚未收到最后归约信息';
}

function renderEvents(events) {
  if (!events.length) { ui.timeline.innerHTML = '<p class="empty-cell">尚无事件</p>'; return; }
  ui.timeline.innerHTML = [...events].reverse().map(e => `<div class="event ${esc(e.level)}"><time>${esc(e.time)}</time><p>${esc(e.message)}</p></div>`).join('');
}

function renderSessionFiles(files) {
  if (!files.length) { ui.sessionFiles.innerHTML = '<p class="empty-cell">尚未建立会话文件</p>'; return; }
  ui.sessionFiles.innerHTML = files.map(f => `<a class="file-link" href="/api/session/download/${encodeURIComponent(f.name)}"><span>${esc(f.name)}</span><span>${Number(f.bytes).toLocaleString()} B</span></a>`).join('');
}

async function refreshStatus() {
  try { renderStatus(await api('/api/status')); } catch (error) { notify(error.message, 'error'); }
}

async function loadGolden() {
  try {
    const g = await api('/api/golden');
    document.getElementById('goldenSummary').innerHTML = `<div class="golden-grid">
      <div><span>程序大小</span>${Number(g.program_bytes).toLocaleString()} byte</div><div><span>程序帧</span>${g.program_frames}</div>
      <div><span>hart0 / hart1提交</span>${g.commit_count['0']} / ${g.commit_count['1']}</div><div><span>总提交</span>${g.commit_count.total}</div>
      <div style="grid-column:1/-1"><span>程序SHA-256</span><code>${esc(g.program_sha256)}</code></div>
    </div>`;
  } catch (error) { notify(error.message, 'error'); }
}

function connectWebSocket() {
  const socket = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`);
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    if (message.type === 'snapshot') renderStatus(message.data);
    else { if (message.level === 'error' || message.type === 'system_frame') notify(message.message, message.level); refreshStatus(); }
  };
  socket.onopen = () => socket.send('ready');
  socket.onclose = () => setTimeout(connectWebSocket, 1500);
}

document.getElementById('refreshInterfaces').addEventListener('click', refreshInterfaces);
document.getElementById('startCapture').addEventListener('click', startCapture);
document.getElementById('stopCapture').addEventListener('click', stopCapture);
document.getElementById('inspectProgram').addEventListener('click', inspectProgram);
document.getElementById('sendPreconfig').addEventListener('click', sendPreconfig);
document.getElementById('sendProgram').addEventListener('click', sendProgram);
document.getElementById('sendEndOnly').addEventListener('click', sendEndOnly);
document.getElementById('clearLogs').addEventListener('click', clearLogs);
document.getElementById('saveLogs').addEventListener('click', saveLogs);

refreshInterfaces(); refreshStatus(); loadGolden(); connectWebSocket(); setInterval(refreshStatus, 2500);
