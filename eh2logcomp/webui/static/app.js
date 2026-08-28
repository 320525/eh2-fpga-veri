const ui = {
  state: document.getElementById('boardState'), lastCode: document.getElementById('lastCode'),
  captureBadge: document.getElementById('captureBadge'), txBadge: document.getElementById('txBadge'),
  interfaceSelect: document.getElementById('interfaceSelect'), diagnostic: document.getElementById('networkDiagnostic'),
  manifest: document.getElementById('programManifest'), programFile: document.getElementById('programFile'),
  progress: document.getElementById('txProgress'), txOperation: document.getElementById('txOperation'), txCount: document.getElementById('txCount'),
  timeline: document.getElementById('eventTimeline'),
  sessionFiles: document.getElementById('sessionFiles'), infoDoneDetails: document.getElementById('infoDoneDetails'), toast: document.getElementById('toast'),
  systemMessageBody: document.getElementById('systemMessageBody'), comparisonSummary: document.getElementById('comparisonSummary')
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

async function resetBoard() {
  if (!confirm('确认停止当前程序发送并对整套FPGA系统执行全局复位？')) return;
  try {
    await api('/api/board/reset', {method:'POST'});
    notify('板级复位命令已排队，等待0x11111111', 'warning');
    await refreshStatus();
  } catch (error) { notify(error.message, 'error'); }
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

async function clearRunCache() {
  if (!confirm('清理之前运行产生的会话、自动化轮次和上传缓存？正在执行的自动化轮次、当前监听会话和正在发送的数据会被保留。')) return;
  try {
    const result = await api('/api/cache/clear', {method:'POST'});
    if (!result.active_tx_preserved) {
      uploadId = null;
      ui.programFile.value = '';
      ui.manifest.className = 'manifest empty';
      ui.manifest.textContent = '尚未载入程序';
    }
    const removedRuns = Number(result.automation_local_runs || 0) +
      Number(result.automation_legacy_runs || 0) + Number(result.automation_shared_runs || 0);
    notify(`缓存清理完成：会话${Number(result.sessions || 0)}个，自动化轮次${removedRuns}个，上传文件${Number(result.upload_files || 0)}个`);
    await refreshStatus();
  } catch (error) { notify(error.message, 'error'); }
}

async function saveLogs() {
  try {
    const result = await api('/api/logs/save', {method:'POST'});
    notify(`日志已保存：${result.file.name}`); await refreshStatus();
  } catch (error) { notify(error.message, 'error'); }
}

async function startAutomation() {
  const body = {
    host: document.getElementById('vmHost').value.trim(),
    port: Number(document.getElementById('vmPort').value),
    username: document.getElementById('vmUser').value.trim(),
    password: document.getElementById('vmPassword').value,
    instructions_per_hart: Number(document.getElementById('autoInstructions').value),
    chunk_instructions: Number(document.getElementById('autoChunkInstructions').value),
    workers: Number(document.getElementById('autoWorkers').value)
  };
  if (!confirm('确认启动连续自动化？PASS按策略清理；指令内容比较FAIL会保留现场并停止；VM任务FAILED或确认的Info回传帧缺失会追加到automation/_wrong.txt、复位板卡并跳到下一轮。')) return;
  try {
    await api('/api/automation/start', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)});
    notify('一键自动化已启动'); await refreshStatus();
  } catch (error) { notify(error.message, 'error'); }
}

async function stopAutomation() {
  if (!confirm('确认停止自动化并保留当前轮次的全部文件？')) return;
  try {
    await api('/api/automation/stop', {method:'POST'});
    notify('自动化已停止，当前文件已保留', 'warning'); await refreshStatus();
  } catch (error) { notify(error.message, 'error'); }
}

function renderAutomation(a = {}, stream = {}) {
  const badge = document.getElementById('automationBadge');
  const active = Boolean(a.enabled);
  const failed = a.state === 'FAILED';
  const canStart = a.can_start !== undefined ? Boolean(a.can_start) : !active;
  badge.textContent = failed ? 'FAIL/已停止' : active ? '运行中' : (a.state || '未启动');
  badge.className = `pill ${failed ? 'error-badge' : active ? 'live' : 'idle'}`;
  const startButton = document.getElementById('startAutomation');
  startButton.disabled = !canStart;
  startButton.textContent = (failed || a.state === 'STOPPED') ?
    '重新启动一键自动化' : '启动一键自动化';
  document.getElementById('stopAutomation').disabled = !active;
  const remote = a.remote_status || {};
  const total = Number(remote.total_chunks || 0);
  const generated = Number(remote.generated_chunks || 0);
  const compiled = Number(remote.compiled_chunks || 0);
  let completed = generated;
  if (String(remote.stage || '').match(/COMPILING|LINKING|PROGRAM_READY|SPIKE/)) completed = Math.max(completed, compiled);
  const percent = total ? Math.min(100, completed * 100 / total) : 0;
  document.getElementById('automationProgress').style.width = `${percent}%`;
  document.getElementById('automationStage').textContent = a.state || 'DISABLED';
  document.getElementById('automationCounts').textContent = `${completed.toLocaleString()} / ${total.toLocaleString()} 块`;
  const result = a.last_result || {};
  const streamExecuted = Number(stream.hart0_records || 0) + Number(stream.hart1_records || 0);
  const executed = Math.max(Number(a.executed_instructions || 0), streamExecuted);
  const compared = Number(a.compared_instructions || 0);
  document.getElementById('instructionCompareCounter').textContent =
    `${executed.toLocaleString()} / ${compared.toLocaleString()}`;
  const hasFailure = String(result.status || '').toUpperCase() === 'FAIL';
  const failureSequence = result.first_failure_sequence;
  const failureHart = result.first_failure_hart;
  document.getElementById('firstFailureSequence').textContent = hasFailure ?
    `hart${failureHart ?? '?'} sequence=${failureSequence ?? '无对应指令'}` : '—';
  const compareStats = a.session_comparison_stats || {};
  document.getElementById('sessionComparedInstructions').textContent =
    Number(compareStats.compared_instructions || 0).toLocaleString();
  document.getElementById('automationSummary').innerHTML =
    `启动会话：<code>${esc(a.automation_session_id || '无')}</code>；轮次：<code>${esc(a.run_id || '无')}</code>；seed：<code>${esc(a.seed || '—')}</code>；` +
    `FPGA日志：${Number(a.fpga_log_frames || 0).toLocaleString()}帧 / ${Number(a.fpga_log_bytes || 0).toLocaleString()} Byte；` +
    `Info完成hart：${esc((a.info_done_harts || []).join(',') || '无')}；` +
    `系统比较：总计 <b>${Number(compareStats.total_comparisons || 0).toLocaleString()}</b>，` +
    `PASS ${Number(compareStats.pass_comparisons || 0).toLocaleString()}，` +
    `FAIL ${Number(compareStats.fail_comparisons || 0).toLocaleString()}` +
    (a.fpga_decoded_file ? `；<a class="file-link inline-link" target="_blank" href="/api/automation/view/${encodeURIComponent(a.fpga_decoded_file)}">打开本轮解码TXT（${Number(a.fpga_decoded_records || 0).toLocaleString()}条有效指令）</a>` : '');
  const timing = a.timings_seconds || {};
  const seconds = value => value === null || value === undefined ? '—' : `${Number(value).toFixed(3)} s`;
  document.getElementById('automationTiming').textContent =
    `阶段耗时：本轮 ${seconds(timing.round_elapsed)}；VM至程序就绪 ${seconds(timing.remote_to_program_ready)}；` +
    `FPGA烧写确认 ${seconds(timing.fpga_program_write)}；执行 ${seconds(timing.fpga_execute)}；` +
    `Info回传 ${seconds(timing.fpga_info_dump)}；Windows比较 ${seconds(timing.comparison)}`;
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
  document.getElementById('rxInfoData').textContent = s.stats.rx_info_data;
  document.getElementById('rxInfoDone').textContent = s.stats.rx_info_done;
  document.getElementById('rxInvalid').textContent = s.stats.rx_invalid;
  document.getElementById('txTotal').textContent = s.stats.tx_total;
  const capture = s.diagnostics?.capture_stats || {};
  const captureMiB = Number(s.diagnostics?.capture_buffer_bytes || 0) / 1048576;
  ui.diagnostic.textContent = `Npcap原始接收缓冲 ${captureMiB.toFixed(0)} MiB；已接收 ${Number(capture.received || 0).toLocaleString()} 帧；内核丢弃 ${Number(capture.dropped || 0).toLocaleString()} 帧；网卡丢弃 ${Number(capture.interface_dropped || 0).toLocaleString()} 帧。`;
  const p = s.tx_progress || {};
  ui.progress.style.width = `${p.percent || 0}%`; ui.txOperation.textContent = p.operation || '无发送任务'; ui.txCount.textContent = `${p.sent || 0} / ${p.total || 0}`;
  renderSystemMessages(s.system_messages || []);
  renderComparison(s.comparison_summary || {}); renderEvents(s.events || []); renderSessionFiles(s.session_files || []);
  renderAutomation(s.automation || {}, s.comparison_summary || {});
}

function renderSystemMessages(items) {
  if (!items.length) { ui.systemMessageBody.innerHTML = '<tr><td colspan="5" class="empty-cell">尚未收到系统信息</td></tr>'; return; }
  ui.systemMessageBody.innerHTML = [...items].reverse().map(item => `<tr>
    <td>${esc(item.received_at || '')}</td><td><code>0x${esc(item.code)}</code></td>
    <td>${esc(item.name)}</td><td>${esc(item.state)}</td><td>${esc(item.description)}</td></tr>`).join('');
}

function renderComparison(summary) {
  const status = summary.status || 'WAITING';
  const cls = status === 'PASS' ? 'pass' : status === 'FAIL' ? 'fail' : 'warning';
  ui.comparisonSummary.className = 'manifest';
  ui.comparisonSummary.innerHTML = `<div><span>双hart完整性</span><b class="${cls}">${esc(status)}</b></div>
    <div><span>hart0 帧 / 记录</span>${summary.hart0_frames || 0} / ${summary.hart0_records || 0}</div>
    <div><span>hart1 帧 / 记录</span>${summary.hart1_frames || 0} / ${summary.hart1_records || 0}</div>
    <div><span>流连续错误</span>hart0=${Boolean(summary.stream_error?.[0])}；hart1=${Boolean(summary.stream_error?.[1])}</div>`;
  const h0 = summary.hart0_done; const h1 = summary.hart1_done;
  const doneText = h => h ? `记录=${h.total_records}，帧=${h.total_frames}，最后sequence=${h.last_sequence}，核对=${h.host_compare}` : '未收到';
  ui.infoDoneDetails.textContent = `hart0结束帧：${doneText(h0)}；hart1结束帧：${doneText(h1)}`;
}

function renderEvents(events) {
  if (!events.length) { ui.timeline.innerHTML = '<p class="empty-cell">尚无事件</p>'; return; }
  ui.timeline.innerHTML = [...events].reverse().map(e => `<div class="event ${esc(e.level)}"><time>${esc(e.time)}</time><p>${esc(e.message)}</p></div>`).join('');
}

function renderSessionFiles(files) {
  if (!files.length) { ui.sessionFiles.innerHTML = '<p class="empty-cell">尚未建立会话文件</p>'; return; }
  ui.sessionFiles.innerHTML = files.map(f => {
    const text = String(f.name).toLowerCase().endsWith('.txt');
    const route = text ? 'view' : 'download';
    return `<a class="file-link" ${text ? 'target="_blank"' : ''} href="/api/session/${route}/${encodeURIComponent(f.name)}"><span>${esc(f.name)}</span><span>${Number(f.bytes).toLocaleString()} B</span></a>`;
  }).join('');
  const decoded = files.find(f => f.name === 'decoded_info_frames.txt');
  const link = document.getElementById('decodedInfoLink');
  link.hidden = !decoded;
  if (decoded) link.href = `/api/session/view/${encodeURIComponent(decoded.name)}`;
}

async function refreshStatus() {
  try { renderStatus(await api('/api/status')); } catch (error) { notify(error.message, 'error'); }
}

async function loadGolden() {
  try {
    const g = await api('/api/golden');
    document.getElementById('goldenSummary').innerHTML = `<div class="golden-grid">
      <div><span>程序大小</span>${Number(g.program_bytes).toLocaleString()} byte</div><div><span>程序帧</span>${g.program_frames}</div>
      <div><span>hart0 / hart1预期Info记录</span>${g.expected_info_records['0']} / ${g.expected_info_records['1']}</div><div><span>预期Info数据帧</span>${g.expected_info_frames.total}</div>
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
document.getElementById('resetBoard').addEventListener('click', resetBoard);
document.getElementById('inspectProgram').addEventListener('click', inspectProgram);
document.getElementById('sendPreconfig').addEventListener('click', sendPreconfig);
document.getElementById('sendProgram').addEventListener('click', sendProgram);
document.getElementById('sendEndOnly').addEventListener('click', sendEndOnly);
document.getElementById('clearLogs').addEventListener('click', clearLogs);
document.getElementById('clearRunCache').addEventListener('click', clearRunCache);
document.getElementById('saveLogs').addEventListener('click', saveLogs);
document.getElementById('startAutomation').addEventListener('click', startAutomation);
document.getElementById('stopAutomation').addEventListener('click', stopAutomation);

refreshInterfaces(); refreshStatus(); loadGolden(); connectWebSocket(); setInterval(refreshStatus, 2500);
