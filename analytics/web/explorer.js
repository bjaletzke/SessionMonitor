/* D3 exploration views over the caller's selected local records. */
(() => {
  'use strict';

  const compact = new Intl.NumberFormat('en', {notation: 'compact', maximumFractionDigits: 1});
  const full = new Intl.NumberFormat('en');
  const fmt = (value) => value == null ? 'Unknown' : compact.format(value);
  const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const palette = () => [1,2,3,4,5,6,7,8].map((i) => cssVar(`--series-${i}`));
  const modelOf = (chat) => chat.model?.trim() || 'Unknown model';
  const harnessOf = (chat) => chat.app || chat.connection_id || 'Unknown harness';
  const dayOf = (value) => value && Number.isFinite(Date.parse(value)) ? new Date(value).toISOString().slice(0, 10) : null;

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  function render(container, {chats = [], events = [], onSelect = () => {}} = {}) {
    container.replaceChildren();
    const root = element('article', 'ae-explorer');
    const ink = {low: cssVar('--seq-low'), high: cssVar('--seq-high'), empty: cssVar('--empty-cell'), unknown: cssVar('--unknown-cell'), dark: cssVar('--accent-ink'), light: cssVar('--text-2')};
    const toolbar = element('div', 'ae-toolbar');
    const tabs = element('div', 'ae-tabs seg');
    tabs.setAttribute('aria-label', 'Visualization');
    const metricLabel = element('label', 'ae-metric-label field inline');
    metricLabel.append(element('span', '', 'Measure'));
    const metric = element('select', 'ae-metric');
    metric.setAttribute('aria-label', 'Visualization measure');
    for (const [value, label] of [['tokens', 'Recorded tokens'], ['count', 'Conversations / events']]) {
      const option = element('option', '', label);
      option.value = value;
      metric.append(option);
    }
    metric.value = container.dataset.explorerMetric === 'count' ? 'count' : 'tokens';
    metricLabel.append(metric);
    const reset = element('button', 'ae-reset button', 'Reset zoom');
    reset.type = 'button';
    toolbar.append(tabs, metricLabel, reset);
    const caption = element('p', 'ae-caption');
    const chart = element('div', 'ae-chart');
    const tooltip = element('div', 'ae-tooltip');
    tooltip.setAttribute('role', 'status');
    tooltip.hidden = true;
    const legend = element('div', 'ae-legend');
    const selection = element('div', 'ae-selection');
    root.append(toolbar, caption, chart, tooltip, legend, selection);
    container.append(root);
    if (!window.d3) {
      chart.append(element('p', 'ae-empty', 'The local D3 library could not be loaded.'));
      return () => root.remove();
    }
    const d3 = window.d3;
    const harnesses = [...new Set(chats.map(harnessOf))].sort();
    const color = d3.scaleOrdinal(harnesses, palette());
    let view = ['matrix', 'scatter', 'calendar'].includes(container.dataset.explorerView) ? container.dataset.explorerView : 'matrix';
    let cleanupChart = () => {};
    let selectionKey = null;
    let lastWidth = 0;
    let closed = false;
    const tabButtons = new Map();
    for (const [key, title] of [['matrix', 'Model × harness'], ['scatter', 'Conversation map'], ['calendar', 'Activity calendar']]) {
      const button = element('button', '', title);
      button.type = 'button';
      button.addEventListener('click', () => {
        view = key;
        container.dataset.explorerView = key;
        selectionKey = null;
        draw();
      });
      tabs.append(button);
      tabButtons.set(key, button);
    }

    function showTooltip(lines) {
      tooltip.replaceChildren(...lines.map((line, index) => element(index ? 'span' : 'strong', '', line)));
      tooltip.hidden = false;
    }

    function groupSelection(label, records) {
      selection.replaceChildren();
      const summary = element('div', 'ae-selection-heading');
      summary.append(element('strong', '', label), element('span', '', `${full.format(records.length)} conversations`));
      selection.append(summary);
      const list = element('div', 'ae-chat-list');
      for (const chat of [...records].sort((a, b) => (b.total_tokens ?? -1) - (a.total_tokens ?? -1)).slice(0, 12)) {
        const button = element('button', 'ae-chat-button item');
        button.type = 'button';
        button.append(element('span', '', chat.title || 'Untitled conversation'),
          element('small', '', `${harnessOf(chat)} · ${fmt(chat.total_tokens)} lifetime tokens`));
        button.addEventListener('click', () => onSelect(chat.id));
        list.append(button);
      }
      selection.append(list);
      if (records.length > 12) selection.append(element('p', '', 'Showing the 12 conversations with the largest recorded lifetime counters in this group.'));
    }

    function svg(width, height, label) {
      return d3.select(chart).append('svg').attr('viewBox', `0 0 ${width} ${height}`)
        .attr('width', width).attr('height', height).attr('role', 'img').attr('aria-label', label);
    }

    function activate(selection, action, lines) {
      selection.attr('tabindex', 0).attr('role', 'button')
        .attr('aria-label', (datum) => lines(datum).join('. '))
        .on('mouseenter focus', (_, datum) => showTooltip(lines(datum)))
        .on('mouseleave blur', () => {tooltip.hidden = true;})
        .on('click', (event, datum) => {if (!event.defaultPrevented) action(datum);})
        .on('keydown', (event, datum) => {
          if (event.key === 'Enter' || event.key === ' ') {event.preventDefault(); action(datum);}
        });
    }

    function drawMatrix(width) {
      const ranked = d3.rollups(chats, (group) => metric.value === 'tokens' ? d3.sum(group, (chat) => chat.total_tokens ?? 0) : group.length, modelOf)
        .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
      const shown = ranked.slice(0, 14).map(([model]) => model);
      const other = new Set(ranked.slice(14).map(([model]) => model));
      const models = [...shown, ...(other.size ? ['__other_models__'] : [])];
      const labelOf = (model) => model === '__other_models__' ? `Other models (${other.size})` : model;
      const groupedModel = (chat) => other.has(modelOf(chat)) ? '__other_models__' : modelOf(chat);
      const minimum = Math.max(430, harnesses.length * 112 + 190);
      const chartWidth = Math.max(width, minimum);
      const margin = {left: 174, top: 56, right: 24, bottom: 25};
      const height = Math.max(220, models.length * 43 + margin.top + margin.bottom);
      const x = d3.scaleBand(harnesses, [margin.left, chartWidth - margin.right]).padding(0.14);
      const y = d3.scaleBand(models, [margin.top, height - margin.bottom]).padding(0.13);
      const groups = d3.group(chats, groupedModel, harnessOf);
      const cells = models.flatMap((model) => harnesses.map((harness) => {
        const records = groups.get(model)?.get(harness) || [];
        const measured = records.filter((chat) => chat.total_tokens != null);
        return {model, harness, records, measured: measured.length,
          value: metric.value === 'count' ? records.length : measured.length ? d3.sum(measured, (chat) => chat.total_tokens) : null};
      }));
      const max = d3.max(cells, (cell) => cell.value) || 1;
      const fill = d3.scaleSequentialSqrt(d3.interpolateRgb(ink.low, ink.high)).domain([0, max]);
      const graphic = svg(chartWidth, height, 'Recorded usage by model and harness. Select a cell to inspect its conversations.');
      graphic.append('g').attr('class', 'ae-column-labels').selectAll('text').data(harnesses).join('text')
        .attr('x', (harness) => x(harness) + x.bandwidth() / 2).attr('y', 31).attr('text-anchor', 'middle').text((harness) => harness);
      graphic.append('g').attr('class', 'ae-row-labels').selectAll('text').data(models).join('text')
        .attr('x', margin.left - 14).attr('y', (model) => y(model) + y.bandwidth() / 2 + 4).attr('text-anchor', 'end')
        .text((model) => labelOf(model).length > 23 ? `${labelOf(model).slice(0, 22)}…` : labelOf(model))
        .append('title').text(labelOf);
      const cell = graphic.append('g').selectAll('g').data(cells).join('g').attr('class', 'ae-cell');
      cell.append('rect').attr('x', (c) => x(c.harness)).attr('y', (c) => y(c.model))
        .attr('width', x.bandwidth()).attr('height', y.bandwidth())
        .attr('fill', (c) => !c.records.length ? ink.empty : c.value == null ? ink.unknown : fill(c.value));
      cell.append('text').attr('x', (c) => x(c.harness) + x.bandwidth() / 2)
        .attr('y', (c) => y(c.model) + y.bandwidth() / 2 + 4).attr('text-anchor', 'middle')
        .attr('fill', (c) => c.value != null && c.value > max * 0.47 ? ink.dark : ink.light)
        .text((c) => !c.records.length ? '—' : fmt(c.value));
      const choose = (cell) => {
        selectionKey = [cell.model, cell.harness];
        groupSelection(`${labelOf(cell.model)} / ${cell.harness}`, cell.records);
      };
      activate(cell.filter((c) => c.records.length), choose, (c) => [
        `${labelOf(c.model)} / ${c.harness}`,
        `${fmt(c.value)} ${metric.value === 'tokens' ? 'recorded lifetime tokens' : 'conversations'}`,
        `${c.measured} of ${c.records.length} chats have counters. Select to inspect.`,
      ]);
      const selected = selectionKey && cells.find((c) => c.model === selectionKey[0] && c.harness === selectionKey[1]);
      if (selected) choose(selected);
      else selection.append(element('p', '', 'Select a cell to see its conversations. Grey cells contain chats without a recorded token total.'));
      legend.append(element('span', '', `Dim → bright: lower → higher ${metric.value === 'tokens' ? 'known token sum' : 'chat count'}.`));
      caption.textContent = 'Chat model selections × hosting application. Tokens are lifetime counters for the selected chats; counts include chats with unknown usage.';
    }

    function drawScatter(width) {
      const points = chats.filter((chat) => dayOf(chat.updated_at) && chat.total_tokens != null);
      if (!points.length) {
        chart.append(element('p', 'ae-empty', 'The conversation map needs chats with a known date and recorded token total.'));
        return;
      }
      const chartWidth = Math.max(450, width), height = 380;
      const margin = {left: 66, right: 25, top: 26, bottom: 55};
      let [first, last] = d3.extent(points, (chat) => Date.parse(chat.updated_at));
      if (first === last) {first -= 86400000; last += 86400000;}
      const x = d3.scaleUtc([new Date(first), new Date(last)], [margin.left, chartWidth - margin.right]);
      const y = d3.scaleSymlog([0, Math.max(1, d3.max(points, (chat) => chat.total_tokens))], [height - margin.bottom, margin.top]).nice();
      const graphic = svg(chartWidth, height, 'Conversation map. Horizontal axis is last activity; vertical axis is lifetime token usage on a symlog scale.');
      const clipId = `ae-clip-${Math.random().toString(36).slice(2)}`;
      graphic.append('defs').append('clipPath').attr('id', clipId).append('rect')
        .attr('x', margin.left).attr('y', margin.top).attr('width', chartWidth - margin.left - margin.right).attr('height', height - margin.top - margin.bottom);
      const horizontal = graphic.append('g').attr('class', 'ae-axis').attr('transform', `translate(0,${height - margin.bottom})`);
      const vertical = graphic.append('g').attr('class', 'ae-axis').attr('transform', `translate(${margin.left},0)`);
      const plot = graphic.append('g').attr('clip-path', `url(#${clipId})`);
      const dots = plot.selectAll('circle').data(points).join('circle').attr('class', 'ae-point')
        .attr('r', 5).attr('fill', (chat) => color(harnessOf(chat))).attr('fill-opacity', 0.74);
      const update = (tx = x, ty = y) => {
        horizontal.call(d3.axisBottom(tx).ticks(Math.max(3, Math.floor(chartWidth / 170))).tickFormat(d3.utcFormat('%d %b')));
        vertical.call(d3.axisLeft(ty).ticks(6).tickFormat((value) => compact.format(value)));
        dots.attr('cx', (chat) => tx(new Date(chat.updated_at))).attr('cy', (chat) => ty(chat.total_tokens));
      };
      update();
      graphic.append('text').attr('class', 'ae-axis-title').attr('x', margin.left).attr('y', 12).text('Lifetime tokens · symlog scale');
      graphic.append('text').attr('class', 'ae-axis-title').attr('x', chartWidth - margin.right).attr('y', height - 8).attr('text-anchor', 'end').text('Last activity · UTC');
      activate(dots, (chat) => onSelect(chat.id), (chat) => [chat.title || 'Untitled conversation',
        `${harnessOf(chat)} · ${modelOf(chat)}`, `${full.format(chat.total_tokens)} lifetime tokens · ${dayOf(chat.updated_at)}`]);
      const zoom = d3.zoom().scaleExtent([1, 30]).extent([[margin.left, margin.top], [chartWidth - margin.right, height - margin.bottom]])
        .translateExtent([[margin.left, margin.top], [chartWidth - margin.right, height - margin.bottom]])
        .filter((event) => event.type === 'wheel' ? event.ctrlKey : !event.button)
        .on('zoom', (event) => update(event.transform.rescaleX(x), event.transform.rescaleY(y)));
      graphic.call(zoom);
      reset.onclick = () => graphic.call(zoom.transform, d3.zoomIdentity);
      cleanupChart = () => {graphic.on('.zoom', null); reset.onclick = null;};
      for (const harness of harnesses) {
        const item = element('span', 'ae-legend-item');
        const dot = element('i'); dot.style.backgroundColor = color(harness);
        item.append(dot, document.createTextNode(harness)); legend.append(item);
      }
      caption.textContent = 'Each dot is a conversation. Drag to pan; Ctrl + wheel to zoom. Select a dot to read the chat. Close dots can overlap.';
      selection.append(element('p', '', `${points.length} chats plotted; ${chats.length - points.length} omitted because a date or token total is unknown. Symlog spacing makes small and large counters visible and supports zero.`));
    }

    function drawCalendar(width) {
      const chatIndex = new Map(chats.map((chat) => [chat.id, chat]));
      const dated = events.filter((event) => dayOf(event.recorded_at) && chatIndex.has(event.chat_id));
      if (!dated.length) {
        chart.append(element('p', 'ae-empty', 'No dated consumption events in this selection. Lifetime totals are available in the other views.'));
        return;
      }
      const last = d3.utcDay.floor(new Date(d3.max(dated, (event) => Date.parse(event.recorded_at))));
      const firstRecorded = d3.utcDay.floor(new Date(d3.min(dated, (event) => Date.parse(event.recorded_at))));
      const first = new Date(Math.max(+firstRecorded, +d3.utcDay.offset(last, -365)));
      const beginning = d3.utcMonday.floor(first);
      const shown = dated.filter((event) => Date.parse(event.recorded_at) >= +first);
      const byDay = d3.group(shown, (event) => dayOf(event.recorded_at));
      const days = d3.utcDay.range(first, d3.utcDay.offset(last, 1)).map((day) => {
        const records = byDay.get(dayOf(day)) || [];
        const measured = records.filter((event) => event.total_tokens != null);
        return {day, records, value: metric.value === 'count' ? records.length : measured.length ? d3.sum(measured, (event) => event.total_tokens) : null};
      });
      const weeks = d3.utcMonday.count(beginning, last) + 1;
      const step = Math.max(14, Math.min(23, (width - 90) / weeks));
      const chartWidth = Math.max(340, weeks * step + 90), height = 226;
      const graphic = svg(chartWidth, height, 'Calendar of recorded consumption events, with Monday through Sunday rows. Select a day to inspect its conversations.');
      const max = d3.max(days, (day) => day.value) || 1;
      const fill = d3.scaleSequentialSqrt(d3.interpolateRgb(ink.low, ink.high)).domain([0, max]);
      const x = (day) => 52 + d3.utcMonday.count(beginning, day) * step;
      const y = (day) => 42 + ((day.getUTCDay() + 6) % 7) * 22;
      graphic.selectAll('.ae-weekday').data(['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']).join('text')
        .attr('class', 'ae-weekday').attr('x', 39).attr('y', (_, index) => 55 + index * 22).attr('text-anchor', 'end').text((label) => label);
      const months = d3.utcMonth.range(d3.utcMonth.ceil(first), d3.utcDay.offset(last, 1));
      const labels = [first, ...months.filter((month) => +month > +d3.utcDay.offset(first, 10))];
      graphic.selectAll('.ae-month').data(labels).join('text').attr('class', 'ae-month')
        .attr('x', x).attr('y', 23).text((day) => d3.utcFormat('%b %Y')(day));
      const cells = graphic.append('g').selectAll('rect').data(days).join('rect').attr('class', 'ae-day')
        .attr('x', (day) => x(day.day)).attr('y', (day) => y(day.day)).attr('width', Math.max(9, step - 4)).attr('height', 17)
        .attr('fill', (day) => !day.records.length ? ink.empty : day.value == null ? ink.unknown : fill(day.value));
      const selectDay = (day) => groupSelection(dayOf(day.day), [...new Set(day.records.map((event) => event.chat_id))].map((id) => chatIndex.get(id)));
      activate(cells.filter((day) => day.records.length), selectDay, (day) => [dayOf(day.day),
        `${fmt(day.value)} ${metric.value === 'tokens' ? 'recorded total tokens' : 'usage events'}`,
        `${day.records.length} usage events. Select to inspect conversations.`]);
      caption.textContent = `Consumption on the recorded event date · UTC. ${metric.value === 'tokens' ? 'Total tokens include each source’s cache semantics.' : 'Counts represent usage events, not chats.'}`;
      legend.append(element('span', '', 'Dim → bright: lower → higher recorded activity. Blank days mean no imported event, not zero provider usage.'));
      selection.append(element('p', '', `Select a day to see its conversations. ${dated.length - shown.length ? `${dated.length - shown.length} earlier events are outside this calendar’s latest 366-day window.` : 'The calendar spans the first through last recorded event in this selection.'}`));
    }

    function draw() {
      if (closed) return;
      cleanupChart(); cleanupChart = () => {};
      chart.replaceChildren(); legend.replaceChildren(); selection.replaceChildren(); tooltip.hidden = true;
      for (const [key, button] of tabButtons) {
        button.classList.toggle('active', key === view);
        button.setAttribute('aria-pressed', String(key === view));
      }
      metricLabel.hidden = view === 'scatter';
      reset.hidden = view !== 'scatter';
      const width = Math.max(280, chart.clientWidth || container.clientWidth || 600);
      lastWidth = width;
      if (!chats.length) {
        caption.textContent = 'This view follows your shared filters.';
        chart.append(element('p', 'ae-empty', 'No conversations match the current selection. Try changing the shared filters.'));
      } else if (view === 'matrix') drawMatrix(width);
      else if (view === 'scatter') drawScatter(width);
      else drawCalendar(width);
    }
    metric.addEventListener('change', () => {
      container.dataset.explorerMetric = metric.value;
      draw();
    });
    const observer = new ResizeObserver(() => {
      const width = chart.clientWidth;
      if (width && Math.abs(width - lastWidth) > 1) draw();
    });
    observer.observe(chart);
    draw();
    return () => {closed = true; observer.disconnect(); cleanupChart(); root.remove();};
  }

  window.AnalyticsExplorer = {render};
})();
