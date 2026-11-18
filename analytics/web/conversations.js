/* Conversation statistics over the caller's filtered local records. */
(() => {
  'use strict';

  const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const palette = () => [1,2,3,4,5,6,7,8].map((i) => cssVar(`--series-${i}`));
  const compact = new Intl.NumberFormat('en', {notation:'compact', maximumFractionDigits:1});
  const decimal = new Intl.NumberFormat('en', {maximumFractionDigits:1});
  const integer = new Intl.NumberFormat('en', {maximumFractionDigits:0});
  const known = (value) => typeof value === 'number' && Number.isFinite(value) && value >= 0;
  const fmt = (value) => known(value) ? compact.format(value) : 'Unknown';
  const average = (sum, count) => known(sum) && known(count) && count > 0 ? sum / count : null;
  const project = (chat) => chat.project_name || 'Unassigned project';
  const projectKey = (chat) => chat.project_id || '__unassigned__';
  const model = (chat) => chat.model || 'Unknown model';
  const promptLength = (chat) => known(chat.avg_user_characters) ? chat.avg_user_characters : average(chat.user_characters, chat.user_messages);
  const responseLength = (chat) => known(chat.avg_assistant_characters) ? chat.avg_assistant_characters : average(chat.assistant_characters, chat.assistant_messages);

  function node(tag, className, text) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text != null) element.textContent = text;
    return element;
  }

  function render(container, {chats = [], summary = {}, onSelect = () => {}, onProjectSelect = () => {}} = {}) {
    const root = node('article', 'cl-laboratory');
    const ink = {prompt: cssVar('--input'), response: cssVar('--output'), low: cssVar('--accent-dim'), high: cssVar('--accent'), bg: cssVar('--bg'), line: cssVar('--line-strong')};
    const metrics = node('div', 'cl-metrics');
    const toolbar = node('div', 'cl-toolbar');
    const tabs = node('div', 'cl-tabs seg');
    tabs.setAttribute('aria-label', 'Conversation analysis view');
    const controls = node('div', 'cl-controls');
    const lensLabel = node('label', 'cl-control-label', 'Measure');
    const lens = node('select');
    lens.setAttribute('aria-label', 'Conversation measure');
    for (const [value,label] of [['messages','Messages per conversation'],['user','Your messages per conversation'],['response','Average response characters']]) {
      const option = node('option','',label); option.value=value; lens.append(option);
    }
    lens.value = ['messages','user','response'].includes(container.dataset.conversationLens) ? container.dataset.conversationLens : 'messages';
    lensLabel.append(lens);
    const groupLabel = node('label','cl-control-label','Compare by');
    const grouping = node('select'); grouping.setAttribute('aria-label','Compare response lengths by');
    for (const [value,label] of [['project','Project'],['model','Model'],['harness','Harness']]) {
      const option=node('option','',label); option.value=value; grouping.append(option);
    }
    grouping.value=['project','model','harness'].includes(container.dataset.conversationGrouping) ? container.dataset.conversationGrouping : 'project';
    groupLabel.append(grouping);
    const brushToggle=node('button','cl-brush-toggle button','Select a range'); brushToggle.type='button';
    const clear = node('button','cl-reset button','Clear selection'); clear.type='button';
    controls.append(lensLabel,groupLabel,brushToggle,clear); toolbar.append(tabs,controls);
    const caption = node('p','cl-caption');
    const workspace = node('div','cl-workspace');
    const canvas = node('div','cl-canvas');
    const chart = node('div','cl-chart');
    const tooltip = node('div','cl-tooltip readout'); tooltip.hidden=true; tooltip.setAttribute('role','status');
    canvas.append(chart,tooltip);
    const inspector = node('aside','cl-inspector'); inspector.setAttribute('aria-label','Selected conversations');
    workspace.append(canvas,inspector);
    const coverage = node('p','cl-coverage');
    root.append(metrics,toolbar,caption,workspace,coverage);
    container.replaceChildren(root);

    const d3=window.d3;
    if (!d3) {
      chart.append(node('p','cl-empty','The local D3 library could not be loaded.'));
      return () => root.remove();
    }
    const measured=chats.filter((chat) => known(chat.total_messages));
    const partial=measured.filter((chat) => chat.stats_partial).length;
    const projects=[...new Set(chats.map(projectKey))].sort();
    const color=d3.scaleOrdinal(projects,palette());
    let view=['distribution','exchange','comparison'].includes(container.dataset.conversationView) ? container.dataset.conversationView : 'distribution';
    let selected=null, selecting=false, closed=false, lastWidth=0, lastHeight=0;
    let cleanupChart=() => {};
    const buttons=new Map();
    for (const [key,label] of [['distribution','Conversation length'],['exchange','Prompt ↔ response'],['comparison','Compare projects']]) {
      const button=node('button','',label); button.type='button';
      button.addEventListener('click',() => {view=key;container.dataset.conversationView=key;selected=null;draw();});
      tabs.append(button); buttons.set(key,button);
    }

    const messages=d3.sum(measured,(c) => c.total_messages);
    const user=d3.sum(measured,(c) => known(c.user_messages) ? c.user_messages : 0);
    const responses=chats.filter((c) => known(c.assistant_messages) && known(c.assistant_characters));
    const prompts=chats.filter((c) => known(c.user_messages) && known(c.user_characters));
    const avgResponses=average(d3.sum(responses,(c) => c.assistant_characters),d3.sum(responses,(c) => c.assistant_messages));
    const avgPrompts=average(d3.sum(prompts,(c) => c.user_characters),d3.sum(prompts,(c) => c.user_messages));
    for (const [label,value,unit] of [
      ['Average conversation',known(summary.avg_messages_per_conversation) ? summary.avg_messages_per_conversation : average(messages,measured.length),'messages'],
      ['Messages you sent',known(summary.user_messages) ? summary.user_messages : measured.length ? user : null,'recorded messages'],
      ['Your messages / chat',known(summary.avg_user_messages_per_conversation) ? summary.avg_user_messages_per_conversation : average(user,measured.length),'messages'],
      ['Assistant messages',known(summary.assistant_messages) ? summary.assistant_messages : measured.length ? d3.sum(measured,(c) => c.assistant_messages || 0) : null,'recorded messages'],
      ['Average response',known(summary.avg_response_characters) ? summary.avg_response_characters : avgResponses,'characters'],
      ['Average prompt',known(summary.avg_prompt_characters) ? summary.avg_prompt_characters : avgPrompts,'characters'],
    ]) {
      const metric=node('div','cl-metric');
      metric.append(node('span','cl-metric-label',label),node('strong','',known(value) ? decimal.format(value) : 'Unknown'),node('small','',unit));
      metrics.append(metric);
    }
    coverage.textContent=`${integer.format(measured.length)} of ${integer.format(chats.length)} selected conversations have message statistics${partial ? ` · ${integer.format(partial)} partial samples` : ''}. Lengths count characters, not tokens. Source omissions, imported history, and sampling can affect these results.`;

    function describe(chat) {
      const prompt=promptLength(chat), response=responseLength(chat);
      return [chat.title || 'Untitled conversation', `${project(chat)} · ${model(chat)} · ${chat.app || chat.connection_id || 'Unknown harness'}`,
        `${fmt(chat.user_messages)} user / ${fmt(chat.assistant_messages)} assistant messages`,
        `${fmt(prompt)} prompt / ${fmt(response)} response characters on average${chat.stats_partial ? ' · partial sample' : ''}`];
    }
    function showTooltip(lines) {
      tooltip.replaceChildren(...lines.map((line,i) => node(i ? 'span':'strong','',line)));
      tooltip.hidden=false;
    }
    function activate(mark, action, describeMark) {
      mark.attr('tabindex',0).attr('role','button').attr('aria-label',(datum) => describeMark(datum).join('. '))
        .on('mouseenter focus',(_,datum) => showTooltip(describeMark(datum)))
        .on('mouseleave blur',() => {tooltip.hidden=true;})
        .on('click',(event,datum) => {if (!event.defaultPrevented) action(datum);})
        .on('keydown',(event,datum) => {if (event.key==='Enter' || event.key===' ') {event.preventDefault();action(datum);}});
    }
    function inspect(records,label) {
      selected={records,label};
      inspector.replaceChildren();
      const head=node('div','cl-inspector-heading');
      head.append(node('span','cl-eyebrow','BEHIND THE NUMBERS'),node('h3','',label),node('p','',`${integer.format(records.length)} conversations`));
      inspector.append(head);
      if (!records.length) {inspector.append(node('p','cl-inspector-empty','No conversations in this range.'));return;}
      const aggregate=node('div','cl-selection-stats');
      aggregate.append(node('span','',`${fmt(d3.sum(records,(c) => c.user_messages || 0))} messages from you`),
        node('span','',`${fmt(d3.sum(records,(c) => c.assistant_messages || 0))} assistant messages`));
      inspector.append(aggregate);
      const keys=new Set(records.map(projectKey));
      if (keys.size===1 && records[0].project_id) {
        const projectButton=node('button','cl-project-action text-button',`Explore ${project(records[0])} →`); projectButton.type='button';
        projectButton.addEventListener('click',() => onProjectSelect(records[0].project_id)); inspector.append(projectButton);
      }
      const list=node('div','cl-chat-list');
      for (const chat of [...records].sort((a,b) => (b.total_messages ?? -1)-(a.total_messages ?? -1)).slice(0,35)) {
        const button=node('button','cl-chat item');button.type='button';
        button.append(node('strong','',chat.title || 'Untitled conversation'),node('span','',project(chat)),
          node('small','',`${fmt(chat.total_messages)} messages · ${fmt(responseLength(chat))} avg response chars${chat.stats_partial ? ' · partial' : ''}`));
        button.addEventListener('click',() => onSelect(chat.id));list.append(button);
      }
      inspector.append(list);
      if (records.length>35) inspector.append(node('p','cl-inspector-footnote','Showing the 35 conversations with the most messages in this selection.'));
    }
    function defaultInspector() {
      inspector.replaceChildren();
      const intro=node('div','cl-inspector-heading');
      intro.append(node('span','cl-eyebrow','EXPLORE THE DETAIL'),node('h3','','Select a shape'),
        node('p','','Brush a range, choose a project, or select a conversation. The data behind your selection appears here.'));
      inspector.append(intro);
      const available=[...measured].sort((a,b) => b.total_messages-a.total_messages).slice(0,5);
      if (available.length) {
        inspector.append(node('h4','cl-small-heading','Longest recorded conversations'));
        for (const chat of available) {
          const button=node('button','cl-chat item');button.type='button';
          button.append(node('strong','',chat.title || 'Untitled conversation'),node('span','',`${fmt(chat.total_messages)} messages · ${project(chat)}`));
          button.addEventListener('click',() => onSelect(chat.id)); inspector.append(button);
        }
      }
    }
    function graphic(width,height,label) {
      return d3.select(chart).append('svg').attr('width',width).attr('height',height).attr('viewBox',`0 0 ${width} ${height}`)
        .attr('role','img').attr('aria-label',label);
    }
    function axes(svg,x,y,width,height,margin,xTitle,yTitle) {
      svg.append('g').attr('class','cl-grid').attr('transform',`translate(${margin.left},0)`).call(d3.axisLeft(y).ticks(5).tickSize(-(width-margin.left-margin.right)).tickFormat(''));
      svg.append('g').attr('class','cl-axis').attr('transform',`translate(0,${height-margin.bottom})`).call(d3.axisBottom(x).ticks(Math.max(3,Math.floor(width/110))).tickFormat((v) => compact.format(v)));
      svg.append('g').attr('class','cl-axis').attr('transform',`translate(${margin.left},0)`).call(d3.axisLeft(y).ticks(5).tickFormat((v) => compact.format(v)));
      svg.append('text').attr('class','cl-axis-title').attr('x',(width+margin.left-margin.right)/2).attr('y',height-10).attr('text-anchor','middle').text(xTitle);
      svg.append('text').attr('class','cl-axis-title').attr('transform',`translate(15,${(height-margin.bottom)/2}) rotate(-90)`).attr('text-anchor','middle').text(yTitle);
    }

    function drawDistribution(width,height) {
      const field=lens.value;
      const value=(chat) => field==='user' ? chat.user_messages : field==='response' ? responseLength(chat) : chat.total_messages;
      const records=chats.filter((chat) => known(value(chat)));
      const label=field==='user' ? 'Your messages per conversation' : field==='response' ? 'Per-chat average response characters' : 'Messages per conversation';
      caption.textContent=`${label}. Each bar counts conversations in a range. ${selecting ? 'Drag across the plot to select a range.' : 'Select a bar, or use Select a range to brush the plot.'} These are recorded conversation statistics${partial ? ', including labelled partial samples' : ''}.`;
      if (!records.length) {chart.append(node('p','cl-empty','No message statistics are available for this measure. Try a source with recorded conversations.'));return;}
      const margin={left:62,right:28,top:45,bottom:62};
      const max=d3.max(records,value) || 1;
      const x=d3.scaleLinear().domain([0,max]).nice().range([margin.left,width-margin.right]);
      const bins=d3.bin().domain(x.domain()).thresholds(Math.min(32,Math.max(7,Math.ceil(Math.sqrt(records.length))))).value(value)(records);
      const y=d3.scaleLinear().domain([0,d3.max(bins,(bin) => bin.length) || 1]).nice().range([height-margin.bottom,margin.top]);
      const svg=graphic(width,height,`${label} distribution. Bars and range selection open the contributing conversations.`);
      axes(svg,x,y,width,height,margin,label,'Conversations');
      const bars=svg.append('g').selectAll('rect').data(bins).join('rect').attr('class','cl-histogram-bar')
        .attr('x',(bin) => x(bin.x0)+2).attr('width',(bin) => Math.max(0,x(bin.x1)-x(bin.x0)-4))
        .attr('y',(bin) => y(bin.length)).attr('height',(bin) => height-margin.bottom-y(bin.length))
        .attr('fill',(bin,i) => d3.interpolateRgb(ink.low,ink.high)(0.2+i/Math.max(1,bins.length)*.8));
      const median=d3.median(records,value);
      svg.append('line').attr('class','cl-median-line').attr('x1',x(median)).attr('x2',x(median)).attr('y1',margin.top-9).attr('y2',height-margin.bottom);
      svg.append('text').attr('class','cl-median-label').attr('x',Math.min(width-margin.right-110,x(median)+7)).attr('y',margin.top-16).text(`Median chat · ${decimal.format(median)}`);
      const choose=(bin) => {bars.classed('muted',(other) => other!==bin);inspect(bin,`${decimal.format(bin.x0)}–${decimal.format(bin.x1)} ${field==='response' ? 'average chars' : 'messages'}`);};
      activate(bars.filter((bin) => bin.length),choose,(bin) => [`${decimal.format(bin.x0)} to ${decimal.format(bin.x1)} ${label.toLowerCase()}`,`${bin.length} conversations. Select to inspect.`]);
      const brush=d3.brushX().extent([[margin.left,margin.top],[width-margin.right,height-margin.bottom]])
        .on('end',(event) => {
          if (!event.sourceEvent || !event.selection) return;
          const [low,high]=event.selection.map(x.invert);
          const recordsInRange=records.filter((chat) => value(chat)>=low && value(chat)<=high);
          bars.classed('muted',(bin) => bin.x1<low || bin.x0>high);
          inspect(recordsInRange,`${decimal.format(low)}–${decimal.format(high)} ${field==='response' ? 'average chars' : 'messages'}`);
        });
      if (selecting) svg.append('g').attr('class','cl-brush').call(brush);
      cleanupChart=() => svg.on('.brush',null);
    }

    function drawExchange(width,height) {
      const records=chats.filter((chat) => known(promptLength(chat)) && known(responseLength(chat)));
      caption.textContent=`Each bubble is one conversation. Horizontal: average prompt characters. Vertical: average response characters. Bubble size follows message count; color identifies project. ${selecting ? 'Drag across the plot to select a region.' : 'Select a bubble, or use Select a region to brush the plot.'} Axes use a symmetric logarithmic scale, including zero.`;
      if (!records.length) {chart.append(node('p','cl-empty','This map needs conversations with both user and assistant character counts.'));return;}
      const margin={left:69,right:30,top:30,bottom:64};
      const x=d3.scaleSymlog().domain([0,d3.max(records,promptLength) || 1]).nice().range([margin.left,width-margin.right]);
      const y=d3.scaleSymlog().domain([0,d3.max(records,responseLength) || 1]).nice().range([height-margin.bottom,margin.top]);
      const r=d3.scaleSqrt().domain([0,d3.max(records,(chat) => chat.total_messages || 0) || 1]).range([4,21]);
      const svg=graphic(width,height,'Prompt and response length map. Select a bubble to open its conversation, or brush an area to inspect a group.');
      axes(svg,x,y,width,height,margin,'Average prompt characters · symlog','Average response characters · symlog');
      const brush=d3.brush().extent([[margin.left,margin.top],[width-margin.right,height-margin.bottom]])
        .on('end',(event) => {
          if (!event.sourceEvent || !event.selection) return;
          const [[x0,y0],[x1,y1]]=event.selection;
          const matching=records.filter((chat) => x(promptLength(chat))>=x0 && x(promptLength(chat))<=x1 && y(responseLength(chat))>=y0 && y(responseLength(chat))<=y1);
          points.classed('muted',(chat) => !matching.includes(chat));inspect(matching,'Selected conversations');
        });
      const points=svg.append('g').selectAll('circle').data(records).join('circle').attr('class','cl-bubble')
        .attr('cx',(chat) => x(promptLength(chat))).attr('cy',(chat) => y(responseLength(chat)))
        .attr('r',(chat) => r(chat.total_messages || 0)).attr('fill',(chat) => color(projectKey(chat)))
        .attr('fill-opacity',.72).attr('stroke',ink.bg).attr('stroke-width',1);
      activate(points,(chat) => onSelect(chat.id),describe);
      if (selecting) svg.append('g').attr('class','cl-brush').call(brush);
      const legend=svg.append('g').attr('class','cl-project-legend');
      const names=[...new Map(records.map((chat) => [projectKey(chat),project(chat)])).entries()].slice(0,4);
      names.forEach(([id,name],i) => {
        legend.append('rect').attr('x',margin.left+i*150-4).attr('y',11).attr('width',8).attr('height',8).attr('fill',color(id));
        legend.append('text').attr('x',margin.left+8+i*150).attr('y',19).text(name.length>20 ? `${name.slice(0,19)}…` : name);
      });
    }

    function drawComparison(width,height) {
      const key=(chat) => grouping.value==='model' ? model(chat) : grouping.value==='harness' ? chat.app || chat.connection_id || 'Unknown harness' : projectKey(chat);
      const label=(chat) => grouping.value==='model' ? model(chat) : grouping.value==='harness' ? chat.app || chat.connection_id || 'Unknown harness' : project(chat);
      const groups=d3.groups(chats,key).map(([id,records]) => {
        const prompts=records.filter((c) => known(c.user_messages) && known(c.user_characters));
        const responses=records.filter((c) => known(c.assistant_messages) && known(c.assistant_characters));
        return {id,label:label(records[0]),records,
          prompt:average(d3.sum(prompts,(c) => c.user_characters),d3.sum(prompts,(c) => c.user_messages)),
          response:average(d3.sum(responses,(c) => c.assistant_characters),d3.sum(responses,(c) => c.assistant_messages))};
      }).filter((group) => known(group.prompt) || known(group.response)).sort((a,b) => (b.response ?? -1)-(a.response ?? -1));
      const shown=groups.slice(0,16);
      caption.textContent=`Compare average prompt and response characters by ${grouping.value}. Averages are weighted by recorded message counts, not by conversation counts. Select a row to inspect its chats.${groups.length>16 ? ' Showing the 16 groups with the longest average responses.' : ''}`;
      if (!shown.length) {chart.append(node('p','cl-empty','No character counts are available to compare.'));return;}
      height=Math.max(height,shown.length*36+100);
      const margin={left:Math.min(200,Math.max(125,width*.24)),right:45,top:52,bottom:55};
      const max=d3.max(shown,(group) => Math.max(group.prompt || 0,group.response || 0)) || 1;
      const x=d3.scaleLinear().domain([0,max]).nice().range([margin.left,width-margin.right]);
      const y=d3.scaleBand().domain(shown.map((group) => group.id)).range([margin.top,height-margin.bottom]).padding(.5);
      const svg=graphic(width,height,'Average prompt and response lengths by group. Blue marks are your prompts; green marks are assistant responses. Select a group to inspect.');
      svg.append('g').attr('class','cl-axis').attr('transform',`translate(0,${height-margin.bottom})`).call(d3.axisBottom(x).ticks(Math.max(3,Math.floor(width/120))).tickFormat((v) => compact.format(v)));
      svg.append('text').attr('class','cl-axis-title').attr('x',(width+margin.left-margin.right)/2).attr('y',height-12).attr('text-anchor','middle').text('Average characters per recorded message');
      const legend=svg.append('g').attr('class','cl-project-legend');
      for (const [i,label,fill] of [[0,'Your prompt',ink.prompt],[1,'Assistant response',ink.response]]) {
        legend.append('rect').attr('x',margin.left+i*140-4).attr('y',16).attr('width',8).attr('height',8).attr('fill',fill);
        legend.append('text').attr('x',margin.left+10+i*140).attr('y',24).text(label);
      }
      const rows=svg.append('g').selectAll('g').data(shown).join('g').attr('class','cl-comparison-row');
      rows.append('rect').attr('x',10).attr('y',(group) => y(group.id)-8).attr('width',width-20).attr('height',y.bandwidth()+16).attr('fill','transparent');
      rows.append('text').attr('class','cl-comparison-label').attr('x',margin.left-15).attr('y',(group) => y(group.id)+y.bandwidth()/2+4).attr('text-anchor','end')
        .text((group) => group.label.length>25 ? `${group.label.slice(0,24)}…` : group.label);
      rows.filter((group) => known(group.prompt) && known(group.response)).append('line')
        .attr('x1',(group) => x(group.prompt)).attr('x2',(group) => x(group.response))
        .attr('y1',(group) => y(group.id)+y.bandwidth()/2).attr('y2',(group) => y(group.id)+y.bandwidth()/2).attr('stroke',ink.line).attr('stroke-width',2);
      for (const [field,fill] of [['prompt',ink.prompt],['response',ink.response]]) {
        rows.filter((group) => known(group[field])).append('circle').attr('cx',(group) => x(group[field]))
          .attr('cy',(group) => y(group.id)+y.bandwidth()/2).attr('r',5).attr('fill',fill).attr('stroke',ink.bg).attr('stroke-width',1.5);
      }
      activate(rows,(group) => inspect(group.records,group.label),(group) => [group.label,`${fmt(group.prompt)} prompt / ${fmt(group.response)} response characters on average`,`${group.records.length} conversations. Select to inspect.`]);
    }

    function draw() {
      if (closed) return;
      cleanupChart();cleanupChart=() => {};chart.replaceChildren();tooltip.hidden=true;
      const width=Math.max(320,chart.clientWidth || container.clientWidth || 800);
      const height=Math.max(370,chart.clientHeight || 460);
      lastWidth=chart.clientWidth;lastHeight=chart.clientHeight;
      for (const [key,button] of buttons) {button.classList.toggle('active',key===view);button.setAttribute('aria-pressed',String(key===view));}
      lensLabel.hidden=view!=='distribution';groupLabel.hidden=view!=='comparison';
      brushToggle.hidden=view==='comparison';brushToggle.textContent=view==='exchange' ? 'Select a region' : 'Select a range';
      brushToggle.classList.toggle('active',selecting);brushToggle.setAttribute('aria-pressed',String(selecting));
      if (!selected) defaultInspector(); else inspect(selected.records,selected.label);
      if (!measured.length) {
        caption.textContent='This view needs message counts and character totals from recorded conversations.';
        chart.append(node('p','cl-empty','No conversation statistics match the current filters. Change the selection or connect a source with recorded messages.'));
      } else if (view==='distribution') drawDistribution(width,height);
      else if (view==='exchange') drawExchange(width,height);
      else drawComparison(width,height);
    }
    lens.addEventListener('change',() => {container.dataset.conversationLens=lens.value;selected=null;draw();});
    grouping.addEventListener('change',() => {container.dataset.conversationGrouping=grouping.value;selected=null;draw();});
    brushToggle.addEventListener('click',() => {selecting=!selecting;draw();});
    clear.addEventListener('click',() => {selected=null;selecting=false;draw();});
    const observer=new ResizeObserver(() => {
      if (Math.abs(chart.clientWidth-lastWidth)>1 || Math.abs(chart.clientHeight-lastHeight)>1) draw();
    });
    observer.observe(chart);draw();
    return () => {closed=true;observer.disconnect();cleanupChart();root.remove();};
  }

  window.ConversationLab={render};
})();
