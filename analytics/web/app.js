const $ = (selector) => document.querySelector(selector);
const state = {data: null, events: [], view: null, scope: null, queryResult: null, queryHasRun: false, scopeVersion: 0, detailVersion: 0, visualVersion: 0, visualCleanup: null};
const compact = new Intl.NumberFormat('en', {notation: 'compact', maximumFractionDigits: 1});
const full = new Intl.NumberFormat('en');
const fmt = (value) => value == null ? 'Unknown' : compact.format(value);
const escape = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'}[c]));
const date = (value) => value ? new Date(value).toLocaleDateString('en-GB', {day:'numeric', month:'short', year:'numeric', timeZone:'UTC'}) : 'Unknown';
const empty = (title, description = '') => `<div class="empty"><strong>${escape(title)}</strong>${escape(description)}</div>`;
const sum = (items, field) => {const values = items.map((r) => r[field]).filter((n) => n != null); return values.length ? values.reduce((a, b) => a + b, 0) : null;};
const presets = {
  'Conversation statistics by project': `SELECT c.project_name, COUNT(s.total_messages) AS measured_chats,
       ROUND(AVG(s.total_messages), 1) AS average_messages,
       SUM(s.user_messages) AS messages_you_sent,
       SUM(s.assistant_messages) AS responses,
       ROUND(1.0 * SUM(s.assistant_characters) / NULLIF(SUM(s.assistant_messages), 0)) AS average_response_characters,
       SUM(s.stats_partial) AS partial_chats
FROM chats c JOIN conversation_stats s ON s.chat_id = c.id
GROUP BY c.project_id
ORDER BY messages_you_sent DESC`,
  'Project and model connections': `SELECT project_name, model, app AS harness,
       COUNT(*) AS conversations, SUM(total_tokens) AS recorded_tokens
FROM chats
GROUP BY project_id, model, app
ORDER BY conversations DESC`,
  'Usage by connection and model': `SELECT connection_id, COALESCE(NULLIF(model, ''), 'Unknown') AS model,
       COUNT(*) AS chats, COUNT(total_tokens) AS measured_chats,
       SUM(total_tokens) AS lifetime_tokens
FROM chats
WHERE is_subagent = 0
GROUP BY connection_id, model
ORDER BY lifetime_tokens DESC`,
  'Daily recorded consumption': `SELECT c.connection_id, substr(e.recorded_at, 1, 10) AS day,
       SUM(e.input_tokens) AS input_tokens,
       SUM(e.output_tokens) AS output_tokens,
       SUM(e.total_tokens) AS total_tokens,
       COUNT(*) AS recorded_events
FROM usage_events e JOIN chats c ON c.id = e.chat_id
WHERE e.recorded_at IS NOT NULL AND c.is_subagent = 0
GROUP BY c.connection_id, day
ORDER BY day DESC`,
  'Largest conversations': `SELECT connection_id, title, model, total_tokens, coverage
FROM chats
WHERE is_subagent = 0
ORDER BY total_tokens DESC
LIMIT 50`,
  'Search recorded conversation text': `SELECT c.connection_id, c.title, m.role, m.recorded_at,
       substr(m.text, 1, 300) AS excerpt
FROM messages m JOIN chats c ON c.id = m.chat_id
WHERE instr(lower(m.text), 'test') > 0
ORDER BY m.recorded_at DESC
LIMIT 100`,
  'Conversation depth and message length': `SELECT c.connection_id, c.title,
       COUNT(m.id) AS sampled_messages,
       SUM(CASE WHEN m.role = 'user' THEN 1 ELSE 0 END) AS user_messages,
       ROUND(AVG(length(m.text))) AS average_characters,
       SUM(m.truncated) AS truncated_messages
FROM chats c JOIN messages m ON m.chat_id = c.id
GROUP BY c.id
ORDER BY sampled_messages DESC`,
  'Chat relationships and provider links': `SELECT a.title AS source_chat, r.kind,
       COALESCE(b.title, r.target_id) AS related_chat,
       CASE WHEN b.id IS NULL THEN 'Outside loaded history' ELSE 'Loaded' END AS coverage
FROM relationships r
LEFT JOIN chats a ON a.id = r.source_id
LEFT JOIN chats b ON b.id = r.target_id
ORDER BY a.title`,
  'Counter coverage': `SELECT connection_id, COUNT(*) AS chats,
       COUNT(total_tokens) AS measured_chats,
       SUM(CASE WHEN total_tokens IS NULL THEN 1 ELSE 0 END) AS unknown_chats
FROM chats
GROUP BY connection_id`,
};
const schema = {
  chats: 'id, connection_id, app, title, model, provider, workspace, created_at, updated_at, parent_id, relationship, host_chat_id, is_subagent, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, total_tokens, coverage, source_path, project_id, project_name, project_path, project_identity',
  conversation_stats: 'chat_id, user_messages, assistant_messages, total_messages, user_characters, assistant_characters, avg_user_characters, avg_assistant_characters, first_message_at, last_message_at, span_seconds, message_coverage, stats_partial',
  messages: 'id, chat_id, role, text, recorded_at, truncated',
  usage_events: 'id, chat_id, recorded_at, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, total_tokens, coverage',
  relationships: 'source_id, target_id, kind',
  connections: 'id, name, path, status, detail, chat_count',
};

async function api(path, body) {
  const response = await fetch(path, body === undefined ? {} : {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)});
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || 'Could not read local data');
  return result;
}
function showError(error) { $('#error').textContent = error.message; $('#error').hidden = false; }
function clearError() { $('#error').hidden = true; }

function filters() {
  return {connection: $('#source').value || 'all', model: $('#model').value,
    provider: $('#provider').value, project: $('#project').value, days: Number($('#range').value),
    include_subagents: $('#workers').checked, merge_copies: $('#merge-copies').checked,
    q: $('#search').value.trim()};
}

function selectedChats() { return state.scope?.chats || []; }

async function refreshScope() {
  const version = ++state.scopeVersion;
  updateFilterBadge();
  state.queryResult = null;
  $('#result-count').textContent = 'Scope changed · run a query';
  $('#query-table').innerHTML = '';
  $('#selection-summary').textContent = 'Updating selection…';
  try {
    const scope = await api('/api/scope', {filters: filters()});
    if (version !== state.scopeVersion) return;
    state.scope = scope;
    state.events = scope.events;
    render();
    if (state.view === 'queries' && state.queryHasRun) await runQuery();
  } catch (error) { if (version === state.scopeVersion) showError(error); }
}

async function renderExplorations(chats) {
  const version = ++state.visualVersion;
  if (state.visualCleanup) state.visualCleanup();
  state.visualCleanup = null;
  const options = {chats, events: state.events, relationships: state.scope.relationships, projects: state.scope.projects || [], summary: state.scope.metrics || {}, onSelect: openChat, onProjectSelect: selectProject};
  if (state.view === 'atlas') state.visualCleanup = window.ProjectAtlas.render($('#atlas-content'), options);
  if (state.view === 'lab') state.visualCleanup = window.ConversationLab.render($('#lab-content'), options);
  if (state.view === 'explorer') state.visualCleanup = window.AnalyticsExplorer.render($('#explorer-content'), options);
  if (state.view === 'constellation') {
    const container = $('#constellation-content');
    container.innerHTML = empty('Loading conversation constellation…');
    try {
      const module = await import('/constellation.js');
      if (version !== state.visualVersion) return;
      state.visualCleanup = module.renderConstellation(container, options);
    } catch (error) { if (version === state.visualVersion) container.innerHTML = empty('Could not load constellation', error.message); }
  }
}

function sorted(chats) {
  return [...chats].sort((a,b) => $('#sort').value === 'recent' ? String(b.updated_at || '').localeCompare(a.updated_at || '') :
    $('#sort').value === 'title' ? String(a.title || '').localeCompare(b.title || '') : (b.total_tokens ?? -1) - (a.total_tokens ?? -1));
}

function metric(label, value, note) {
  return `<article class="metric"><div class="label">${escape(label)}</div><strong>${escape(value)}</strong><small>${note}</small></article>`;
}

function chatTable(chats) {
  if (!chats.length) return empty('No conversations in this selection', 'Try a different connection, date range, or search.');
  return `<table><thead><tr><th>Conversation</th><th>Model</th><th>Messages · you / assistant</th><th>Lifetime tokens</th><th>Last activity · UTC</th></tr></thead><tbody>${chats.map((r) => `<tr data-id="${escape(r.id)}" tabindex="0" aria-label="Open ${escape(r.title)}"><td><span class="chat-title">${escape(r.title || 'Untitled conversation')}</span><span class="chat-meta">${escape(r.project_name || r.workspace?.split('/').filter(Boolean).pop() || 'Unknown project')} · ${escape(r.app)}${r.is_subagent ? ' · Subagent' : ''}${r.host_chat_id ? ' · Linked to T3' : ''}</span></td><td><span class="tag">${escape(r.model || 'Unknown model')}</span></td><td>${r.total_messages == null ? 'Unknown' : `${full.format(r.user_messages ?? 0)} / ${full.format(r.assistant_messages ?? 0)}${r.stats_partial ? ' · partial' : ''}`}</td><td class="token-value" title="${r.total_tokens == null ? 'No recorded counter' : escape(full.format(r.total_tokens))}">${fmt(r.total_tokens)}</td><td>${date(r.updated_at)}</td></tr>`).join('')}</tbody></table>`;
}

function timeline(chats) {
  const ids = new Set(chats.map((r) => r.id));
  const days = Number($('#range').value);
  const now = new Date();
  const end = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const start = days ? end - (days - 1) * 86400000 : 0;
  const events = state.events.filter((e) => ids.has(e.chat_id) && e.recorded_at && Date.parse(e.recorded_at) >= start && Date.parse(e.recorded_at) <= Date.now());
  if (!events.length) {
    $('#timeline').innerHTML = empty('No dated consumption in this selection', 'Lifetime counters are available in the table. Context snapshots are excluded.');
    return;
  }
  const first = days ? start : events.reduce((minimum,e) => Math.min(minimum,Date.parse(e.recorded_at)),end);
  const monthly = (end - first) / 86400000 > 60;
  const key = (d) => new Date(d).toISOString().slice(0, monthly ? 7 : 10);
  const buckets = new Map();
  const cursor = new Date(first);
  cursor.setUTCHours(0,0,0,0);
  if (monthly) cursor.setUTCDate(1);
  for (let i=0; cursor.getTime() <= end && i < 600; i++) {
    buckets.set(key(cursor), {input:0, output:0, count:0});
    if (monthly) cursor.setUTCMonth(cursor.getUTCMonth()+1); else cursor.setUTCDate(cursor.getUTCDate()+1);
  }
  for (const event of events) {
    const bucket = buckets.get(key(event.recorded_at));
    if (bucket) { bucket.input += event.input_tokens ?? 0; bucket.output += event.output_tokens ?? 0; bucket.count++; }
  }
  const maximum = Math.max(1, ...[...buckets.values()].map((b) => b.input + b.output));
  const interval = Math.max(1, Math.ceil(buckets.size / 6));
  $('#timeline').innerHTML = `<div class="plot"><span class="plot-max">${fmt(maximum)}</span>${[...buckets].map(([day,b], i) => `<div class="plot-column" title="${escape(day)}: ${full.format(b.input)} input, ${full.format(b.output)} output · ${b.count} recorded events"><div class="bar-output" data-height="${b.output / maximum * 95}"></div><div class="bar-input" data-height="${b.input / maximum * 95}"></div>${i % interval === 0 ? `<span class="plot-label">${monthly ? day : date(day).replace(/ \d{4}$/, '')}</span>` : ''}</div>`).join('')}</div>`;
  for (const bar of document.querySelectorAll('[data-height]')) bar.style.height = `${bar.dataset.height}%`;
}

function modelChart(chats) {
  const groups = new Map();
  for (const chat of chats) {
    if (chat.total_tokens != null) groups.set(chat.model || 'Unknown model', (groups.get(chat.model || 'Unknown model') || 0) + chat.total_tokens);
  }
  const values = [...groups].sort((a,b) => b[1]-a[1]);
  if (!values.length) { $('#models').innerHTML = empty('No model usage recorded'); return; }
  const shown = values.slice(0,4);
  if (values.length > 4) shown.push(['Other models', values.slice(4).reduce((total, [,v]) => total + v, 0)]);
  const max = Math.max(1, ...shown.map(([,v]) => v));
  $('#models').innerHTML = shown.map(([name,value]) => `<div class="model"><div class="model-line"><span title="${escape(name)}">${escape(name)}</span><span>${fmt(value)}</span></div><div class="model-track"><div class="model-bar" data-width="${value / max * 100}"></div></div></div>`).join('');
  for (const bar of document.querySelectorAll('[data-width]')) bar.style.width = `${bar.dataset.width}%`;
}

function render() {
  if (!state.data || !state.scope) return;
  const chats = selectedChats();
  const measured = chats.filter((r) => r.total_tokens != null);
  const models = new Set(chats.map((r) => r.model).filter(Boolean));
  const coverage = chats.length ? Math.round(measured.length / chats.length * 100) : 0;
  $('#metrics').innerHTML = metric('Recorded lifetime tokens', fmt(sum(chats,'total_tokens')), `<b>${measured.length}</b> of ${chats.length} chats have counters`) +
    metric('Conversations', full.format(chats.length), 'In the selected activity window') +
    metric('Models used', models.size, 'Recorded chat model selection') +
    metric('Counter coverage', `${coverage}%`, 'Presence of counters, including partial');
  $('#top-table').innerHTML = chatTable([...chats].sort((a,b) => (b.total_tokens ?? -1) - (a.total_tokens ?? -1)).slice(0,6));
  $('#chat-table').innerHTML = chatTable(sorted(chats));
  const m = state.scope.metrics || {};
  $('#conversation-metrics').innerHTML = metric('Average conversation', m.avg_messages_per_conversation == null ? 'Unknown' : full.format(Math.round(m.avg_messages_per_conversation * 10) / 10), 'Visible messages per measured chat') + metric('Messages you sent', fmt(m.user_messages), `${m.measured_chats || 0} measured chats · ${m.partial_chats || 0} partial`) + metric('Average response', m.avg_response_characters == null ? 'Unknown' : full.format(Math.round(m.avg_response_characters)), 'Characters per recorded assistant message') + metric('Projects in view', state.scope.projects?.length || 0, 'Recorded project or verified repository identity');
  const connection = state.data.connections.find((c) => c.id === $('#source').value);
  const grouped = state.scope.summary.grouped_records;
  $('#selection-summary').textContent = `${full.format(chats.length)} conversations · ${$('#source').selectedOptions[0]?.textContent || 'All connections'} · ${$('#range').selectedOptions[0].textContent}${$('#project').value ? ` · ${$('#project').selectedOptions[0].textContent}` : ''}${grouped ? ` · ${grouped} exact source copies grouped` : ''}`;
  $('#chat-count').textContent = full.format(chats.length);
  $('#scope').textContent = `${connection?.detail || 'Combined connection view. Exact T3/provider identities and matching snapshot IDs are grouped when enabled. Unknown identity matches and fork histories may still overlap.'} Lifetime totals cover selected chats; the activity date filter selects chats by last activity. Dated charts use only recorded event timestamps in the date window. Source counters may be partial. Token counts are not billing amounts.`;
  timeline(chats); modelChart(chats); renderConnections(); renderExplorations(chats);
}

function renderConnections() {
  $('#connection-cards').innerHTML = (state.scope?.connections || state.data.connections).map((c) => `<article class="card connection"><span class="status ${c.status !== 'connected' ? 'off' : ''}">${c.status === 'connected' ? '● Connected' : '○ Unavailable'}</span><h2>${escape(c.name)}</h2><code>${escape(c.path)}</code><strong class="connection-count">${full.format(c.selected_count ?? c.chat_count)} <small class="muted">selected / ${full.format(c.chat_count)} loaded chats</small></strong><p>${escape(c.detail)}</p>${c.status === 'connected' ? `<button class="text-button explore-source" data-source="${escape(c.id)}">Explore this connection →</button>` : ''}</article>`).join('');
}

async function load(refresh = false) {
  $('#refresh').disabled = true;
  try {
    clearError();
    const data = refresh ? await api('/api/refresh', {}) : await api('/api/data');
    state.data = data;
    const previous = $('#source').value || 'all';
    $('#source').innerHTML = '<option value="all">All connections</option>' + data.connections.map((c) => `<option value="${escape(c.id)}">${escape(c.name)}${c.status !== 'connected' ? ' · unavailable' : ''}</option>`).join('');
    $('#source').value = data.connections.some((c) => c.id === previous) ? previous : 'all';
    for (const field of ['model','provider']) {
      const select = $('#' + field), previous = select.value;
      const values = [...new Set(data.chats.map((c) => c[field]).filter(Boolean))].sort();
      select.innerHTML = `<option value="">All ${field === 'model' ? 'models' : 'providers / instances'}</option><option value="__unknown__">Unknown ${field}</option>` + values.map((value) => `<option value="${escape(value)}">${escape(value)}</option>`).join('');
      if ([...select.options].some((option) => option.value === previous)) select.value = previous;
    }
    const previousProject = $('#project').value;
    const projects = new Map(data.chats.map((chat) => [chat.project_id || 'unknown', chat.project_name || 'Unknown project']));
    $('#project').innerHTML = '<option value="">All projects</option>' + [...projects].sort((a,b) => a[1].localeCompare(b[1])).map(([id,name]) => `<option value="${escape(id)}">${escape(name)}</option>`).join('');
    if (projects.has(previousProject)) $('#project').value = previousProject;
    const refreshed = new Date(data.refreshed_at).toLocaleTimeString('en-GB', {hour:'2-digit', minute:'2-digit'});
    $('#updated').textContent = refreshed; $('#updated').title = `Sources last read at ${refreshed}`;
    await refreshScope();
  } catch (error) { showError(error); }
  finally { $('#refresh').disabled = false; }
}

const views = {
  atlas: ['Project atlas', 'Projects connected to the models and harnesses recorded in their conversations.'],
  lab: ['Conversation lab', 'Distributions of conversation length, prompts, and responses. Open the chats behind each mark.'],
  constellation: ['Constellation', 'Conversations in 3D, clustered by project, model, or harness. Lines are recorded relationships.'],
  explorer: ['Usage explorer', 'Model × harness matrix, conversation map, and activity calendar.'],
  overview: ['Overview', 'Recorded usage, conversation statistics, and the largest conversations in this selection.'],
  chats: ['Conversations', 'Every selected conversation. Open one to read its messages, counters, and relationships.'],
  queries: ['Query studio', 'Read-only SQL over the selected projection.'],
  connections: ['Connections', 'Configured sources, their coverage, and selected versus loaded counts.'],
};
const viewFromHash = () => {const view = location.hash.replace(/^#\/?/, ''); return views[view] ? view : 'atlas';};

function switchView(view) {
  if (!views[view]) view = 'atlas';
  const changed = view !== state.view;
  state.view = view;
  document.body.dataset.view = view;
  document.body.classList.toggle('canvas', ['atlas','lab','constellation'].includes(view));
  for (const section of document.querySelectorAll('.view')) section.hidden = section.id !== view;
  for (const link of document.querySelectorAll('.viewnav [data-view]')) {
    if (link.dataset.view === view) link.setAttribute('aria-current', 'page'); else link.removeAttribute('aria-current');
  }
  const [title, description] = views[view];
  $('#page-title').textContent = title; $('#page-description').textContent = description;
  document.title = `${title} · Session Monitor`;
  $('#export').hidden = view === 'connections';
  if (changed) { $('#workspace').scrollTop = 0; clearError(); }
  const nav = $('.viewnav'), current = nav.querySelector('[aria-current]');
  if (current.offsetLeft < nav.scrollLeft || current.offsetLeft + current.offsetWidth > nav.scrollLeft + nav.clientWidth) nav.scrollLeft = current.offsetLeft - 12;
  if (state.scope) renderExplorations(selectedChats());
  if (view === 'queries' && state.queryHasRun && !state.queryResult) runQuery();
}
function navigate(view) {
  if (location.hash === `#/${view}`) switchView(view); else location.hash = `#/${view}`;
}

async function openChat(id) {
  const chat = selectedChats().find((c) => c.id === id) || state.data.chats.find((c) => c.id === id);
  if (!chat) return;
  const version = ++state.detailVersion;
  $('#detail-content').innerHTML = empty('Loading conversation…');
  if (!$('#detail').open) $('#detail').showModal();
  try {
    const detail = await api(`/api/chat?id=${encodeURIComponent(id)}`);
    if (version !== state.detailVersion) return;
    const messages = detail.messages;
    const stats = detail.stats || chat;
    const average = stats.avg_user_characters == null ? null : Math.round(stats.avg_user_characters);
    const links = state.data.relationships.filter((r) => r.source_id === id || r.target_id === id);
    $('#detail-content').innerHTML = `<div class="detail-heading"><h2>${escape(chat.title)}</h2><p>${escape(chat.app)} · ${escape(chat.model || 'Unknown model')} · ${date(chat.updated_at)}</p><p>${escape(chat.project_name || 'Unknown project')} · ${escape(chat.project_path || chat.workspace)}</p>${chat.workspace && chat.workspace !== chat.project_path ? `<p>Workspace: ${escape(chat.workspace)}</p>` : ''}</div><div class="detail-metrics">${metric('Lifetime tokens', fmt(chat.total_tokens), escape(chat.coverage || 'Coverage unavailable'))}${metric('Input / output', `${fmt(chat.input_tokens)} / ${fmt(chat.output_tokens)}`, 'Provider counter semantics apply')}${metric('Recorded messages', fmt(stats.total_messages), `${fmt(stats.user_messages)} user · ${fmt(stats.assistant_messages)} assistant${stats.stats_partial ? ' · partial' : ''}`)}${metric('Cache read', fmt(chat.cache_read_tokens), 'Included in input for T3 and Codex')}${metric('Reasoning', fmt(chat.reasoning_tokens), 'Included in output for T3 and Codex')}${metric('Average user message', average == null ? 'Unknown' : full.format(average), 'Characters per recorded user message')}${metric('Average response', stats.avg_assistant_characters == null ? 'Unknown' : full.format(Math.round(stats.avg_assistant_characters)), 'Characters per recorded assistant message')}${metric('Message coverage', stats.stats_partial ? 'Partial' : stats.total_messages == null ? 'Unknown' : 'Local record', escape(stats.message_coverage || 'No full conversation statistics available'))}</div><p>${escape(chat.coverage || '')}</p><section class="detail-section"><h3>Recurring terms in your messages</h3><p>Local word frequency in loaded user text. This does not measure quality, sentiment, or outcomes.</p><div class="terms">${detail.terms.map(([word,count]) => `<span class="term">${escape(word)}<span>${count}</span></span>`).join('') || '<p>No user text available in this sample.</p>'}</div></section><section class="detail-section"><h3>Connections to other chats</h3>${links.map((r) => {const other = r.source_id === id ? r.target_id : r.source_id; const linked = state.data.chats.find((c) => c.id === other); return linked ? `<button class="relation" data-related="${escape(other)}">${escape(linked.title)}<small>${escape(r.kind)} · ${r.source_id === id ? 'outgoing' : 'incoming'} relation</small></button>` : `<p class="relation">${escape(other)}<small>${escape(r.kind)} · outside loaded history</small></p>`;}).join('') || '<p>No explicit relationships recorded.</p>'}</section><section class="detail-section"><h3>Recorded conversation · ${messages.length} sampled messages</h3><p>Only user and assistant text is shown. Messages may be sampled or truncated; tool output and hidden reasoning are excluded.</p>${messages.map((m) => `<article class="message"><div class="message-head"><span>${escape(m.role)}${m.truncated ? ' · truncated' : ''}</span><span>${date(m.recorded_at)}</span></div><pre>${escape(m.text)}</pre></article>`).join('') || empty('No conversation text loaded', 'Try a source with local transcripts or import an existing Swift snapshot.')}</section>`;
  } catch (error) { $('#detail-content').innerHTML = empty('Could not load conversation', error.message); }
}

function genericTable(result) {
  if (!result.rows.length) return empty('Query returned no rows');
  return `<table><thead><tr>${result.columns.map((c) => `<th>${escape(c)}</th>`).join('')}</tr></thead><tbody>${result.rows.map((r) => `<tr>${r.map((v) => `<td title="${escape(v)}">${escape(v == null ? 'NULL' : typeof v === 'object' ? JSON.stringify(v) : v)}</td>`).join('')}</tr>`).join('')}</tbody></table>`;
}

async function runQuery() {
  $('#run-query').disabled = true;
  try {
    clearError();
    const version = state.scopeVersion;
    const result = await api('/api/query', {sql:$('#sql').value, filters: filters()});
    if (version !== state.scopeVersion) return;
    state.queryResult = result; state.queryHasRun = true;
    $('#query-table').innerHTML = genericTable(state.queryResult);
    $('#result-count').textContent = `${state.queryResult.rows.length} rows${state.queryResult.truncated ? ' · row or size limit reached' : ''}${state.queryResult.cells_truncated ? ' · large cells truncated' : ''}`;
  } catch (error) { state.queryResult = null; $('#query-table').innerHTML = ''; $('#result-count').textContent = 'Query failed'; showError(error); }
  finally { $('#run-query').disabled = false; }
}

function exportTable() {
  const result = state.view === 'queries' ? state.queryResult : {
    columns:['id','app','title','model','project_name','total_messages','user_messages','assistant_messages','avg_assistant_characters','stats_partial','workspace','updated_at','input_tokens','output_tokens','cache_read_tokens','reasoning_tokens','total_tokens','coverage'],
    rows:selectedChats().map((r) => ['id','app','title','model','project_name','total_messages','user_messages','assistant_messages','avg_assistant_characters','stats_partial','workspace','updated_at','input_tokens','output_tokens','cache_read_tokens','reasoning_tokens','total_tokens','coverage'].map((c) => r[c])),
  };
  if (!result) { showError(new Error('Run a query before exporting its results.')); return; }
  const cell = (v) => {let s = String(v ?? ''); if (typeof v === 'string' && /^[=+\-@\t\r\n]/.test(s)) s = "'" + s; return `"${s.replace(/"/g,'""')}"`;};
  const csv = [result.columns,...result.rows].map((r) => r.map(cell).join(',')).join('\r\n');
  const url = URL.createObjectURL(new Blob(['\ufeff',csv], {type:'text/csv;charset=utf-8'}));
  const a = document.createElement('a'); a.href=url; a.download='session-monitor-analytics.csv'; a.click(); setTimeout(() => URL.revokeObjectURL(url),1000);
}

function selectProject(id) {
  const option = [...$('#project').options].find((option) => option.value === id);
  if (!option) return;
  $('#project').value = id;
  refreshScope();
}
function setFiltersCollapsed(collapsed) {
  document.body.classList.toggle('scope-collapsed', collapsed);
  $('#scope-toggle').setAttribute('aria-expanded', String(!collapsed));
  try { localStorage.setItem('sm-filters-collapsed', collapsed ? '1' : '0'); } catch {}
}
function updateFilterBadge() {
  const active = ['#search','#project','#model','#provider'].filter((id) => $(id).value.trim()).length + ($('#source').value && $('#source').value !== 'all' ? 1 : 0) + ($('#range').value !== '0' ? 1 : 0);
  $('#scope-toggle').textContent = active ? `Filters · ${active}` : 'Filters';
  $('#scope-toggle').classList.toggle('has-active', active > 0);
}
$('#scope-toggle').addEventListener('click', () => setFiltersCollapsed(!document.body.classList.contains('scope-collapsed')));
{
  let stored = null;
  try { stored = localStorage.getItem('sm-filters-collapsed'); } catch {}
  setFiltersCollapsed(stored == null ? matchMedia('(max-width: 800px)').matches : stored === '1');
}
window.addEventListener('hashchange', () => switchView(viewFromHash()));
document.addEventListener('keydown', (event) => {
  if (event.metaKey || event.ctrlKey || event.altKey || $('#detail').open) return;
  if (event.target.closest('input, textarea, select, [contenteditable]')) return;
  const index = Number(event.key);
  if (Number.isInteger(index) && index >= 1 && index <= 8) navigate(Object.keys(views)[index - 1]);
});

let searchTimer;
$('#search').addEventListener('input', () => {state.scopeVersion++; clearTimeout(searchTimer); searchTimer = setTimeout(refreshScope,200);});
for (const id of ['#source','#project','#range','#workers','#model','#provider','#merge-copies']) $(id).addEventListener('change',refreshScope);
$('#sort').addEventListener('change', render);
$('#refresh').addEventListener('click', () => load(true));
$('#export').addEventListener('click',exportTable);
$('#all-chats').addEventListener('click',() => navigate('chats'));
$('#close-detail').addEventListener('click',() => {state.detailVersion++; $('#detail').close();});
$('#run-query').addEventListener('click',runQuery);
$('#sql').addEventListener('keydown',(event) => {if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') {event.preventDefault(); runQuery();}});
$('#query-preset').innerHTML = Object.keys(presets).map((name) => `<option>${escape(name)}</option>`).join('');
$('#query-preset').addEventListener('change',() => {$('#sql').value = presets[$('#query-preset').value];});
$('#sql').value = Object.values(presets)[0];
$('#schema').innerHTML = Object.entries(schema).map(([table,fields]) => `<details><summary>${table}</summary><p>${escape(fields)}</p></details>`).join('');
document.addEventListener('click',(event) => {
  const row = event.target.closest('tr[data-id]'); if (row) openChat(row.dataset.id);
  const related = event.target.closest('[data-related]'); if (related) openChat(related.dataset.related);
  const source = event.target.closest('[data-source]'); if (source) {$('#source').value = source.dataset.source; navigate('overview'); refreshScope();}
});
document.addEventListener('keydown',(event) => {const row = event.target.closest('tr[data-id]'); if (row && (event.key === 'Enter' || event.key === ' ')) {event.preventDefault(); openChat(row.dataset.id);}});
switchView(viewFromHash());
load();
