/* Project context from recorded chat membership. All rendering stays local. */
(() => {
  'use strict';
  const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const palette = () => [1,2,3,4,5,6,7,8].map((i) => cssVar(`--series-${i}`));
  const number = new Intl.NumberFormat('en');
  const compact = new Intl.NumberFormat('en', {notation:'compact',maximumFractionDigits:1});
  const fmt = (value) => value == null ? 'Unknown' : compact.format(value);
  const node = (tag, className, text) => {
    const result=document.createElement(tag);
    if (className) result.className=className;
    if (text != null) result.textContent=text;
    return result;
  };
  const projectOf = (chat) => chat.project_id || chat.project_path || chat.workspace || '__unassigned__';
  const modelOf = (chat) => chat.model || 'Unknown model';
  const harnessOf = (chat) => chat.app || chat.connection_id || 'Unknown harness';
  const messageCount = (chat) => chat.total_messages ?? ((chat.user_messages != null || chat.assistant_messages != null) ? (chat.user_messages || 0)+(chat.assistant_messages || 0) : null);
  const sumKnown = (chats, read) => {
    const values=chats.map(read).filter((value) => value != null && Number.isFinite(value));
    return values.length ? values.reduce((sum,value) => sum+value,0) : null;
  };

  function render(container, {chats=[],projects=[],onSelect=()=>{},onProjectSelect=()=>{}}={}) {
    const d3=window.d3;
    container.replaceChildren();
    const root=node('article','pa-atlas');
    const toolbar=node('div','pa-toolbar');
    const COLORS=palette();
    const modes=node('div','pa-modes seg');modes.setAttribute('aria-label','Atlas layout');
    const modeButtons=new Map();
    let mode=['network','chord'].includes(container.dataset.atlasMode)?container.dataset.atlasMode:'network';
    for (const [value,label] of [['network','Network map'],['chord','Chord flows']]) {
      const button=node('button','',label);button.type='button';
      button.addEventListener('click',()=>{mode=value;container.dataset.atlasMode=value;draw();});
      modes.append(button);modeButtons.set(value,button);
    }
    const dimension=node('select','pa-dimension');dimension.setAttribute('aria-label','Atlas connection dimension');
    for (const [value,label] of [['model','Projects ↔ models'],['harness','Projects ↔ harnesses']]) {
      const option=node('option','',label);option.value=value;dimension.append(option);
    }
    dimension.value=container.dataset.atlasDimension||'model';
    const measure=node('select','pa-measure');measure.setAttribute('aria-label','Atlas measure');
    for (const [value,label] of [['chats','Conversation count'],['messages','Message count'],['tokens','Recorded tokens']]) {
      const option=node('option','',label);option.value=value;measure.append(option);
    }
    measure.value=container.dataset.atlasMeasure||'chats';
    const reset=node('button','pa-reset button','Reset view');reset.type='button';
    toolbar.append(modes,dimension,measure,reset);
    const summary=node('div','pa-summary');
    const body=node('div','pa-body');
    const stage=node('div','pa-stage');
    const canvas=node('div','pa-canvas');
    const status=node('div','pa-status');
    const tooltip=node('div','pa-tooltip readout');tooltip.hidden=true;tooltip.setAttribute('role','status');
    const zoomHint=node('span','pa-zoom-hint','Drag nodes · pan canvas · scroll to zoom');
    stage.append(canvas,status,tooltip,zoomHint);
    const inspector=node('aside','pa-inspector');inspector.setAttribute('aria-label','Atlas selection');
    body.append(stage,inspector);
    const foot=node('div','pa-footnote');
    root.append(toolbar,summary,body,foot);container.append(root);
    if (!d3) {canvas.append(node('p','pa-empty','The local D3 library could not be loaded.'));return ()=>root.remove();}

    const metadata=new Map(projects.map((project)=>[project.id,project]));
    const grouped=d3.group(chats,projectOf);
    const projectGroups=[...grouped].map(([id,records])=>{
      const meta=metadata.get(id)||{};
      const first=records[0]||{};
      const path=meta.path || first.project_path || first.workspace || '';
      const name=meta.name || first.project_name || path.split('/').filter(Boolean).pop() || 'No recorded project';
      return {id:`project:${id}`,projectId:id,kind:'project',name,path,identity:meta.identity||'',records};
    });
    const projectById=new Map(projectGroups.map((project)=>[project.projectId,project]));
    let selected=null, focusProject='';
    let cleanupChart=()=>{};
    let closed=false, lastWidth=0,lastHeight=0;
    const metric=(records)=>measure.value==='chats'?records.length:sumKnown(records,measure.value==='messages'?messageCount:(chat)=>chat.total_tokens);
    const metricName=()=>measure.value==='chats'?'conversations':measure.value==='messages'?'recorded messages':'recorded lifetime tokens';
    const categoryOf=(chat)=>dimension.value==='model'?modelOf(chat):harnessOf(chat);
    const color=(index)=>COLORS[index%COLORS.length];

    function showTooltip(lines) {
      tooltip.replaceChildren(...lines.map((line,index)=>node(index?'span':'strong','',line)));
      tooltip.hidden=false;
    }
    function groupInfo(group) {
      const records=group.records;
      return [group.name,`${number.format(records.length)} conversations · ${fmt(sumKnown(records,messageCount))} messages`,
        `${fmt(sumKnown(records,(chat)=>chat.total_tokens))} recorded lifetime tokens`,
        group.kind==='project'?(group.path||'No workspace path recorded'):`${new Set(records.map(projectOf)).size} recorded projects`];
    }
    function selectGroup(group, activateProject=false) {
      selected=group;
      inspector.replaceChildren();
      inspector.append(node('span','pa-eyebrow',group.kind==='project'?'PROJECT CONTEXT':dimension.value==='model'?'MODEL CONTEXT':'HARNESS CONTEXT'),
        node('h3','',group.name));
      if (group.path) inspector.append(node('p','pa-path',group.path));
      if (group.identity) inspector.append(node('p','pa-identity',`Identity: ${group.identity}`));
      const facts=node('div','pa-facts');
      for (const [label,value] of [['Conversations',group.records.length],['User messages',sumKnown(group.records,(chat)=>chat.user_messages)],['Assistant messages',sumKnown(group.records,(chat)=>chat.assistant_messages)],['Lifetime tokens',sumKnown(group.records,(chat)=>chat.total_tokens)]]) {
        const fact=node('div');fact.append(node('strong','',fmt(value)),node('span','',label));facts.append(fact);
      }
      inspector.append(facts);
      const context=node('div','pa-context');
      const models=[...new Set(group.records.map(modelOf))], harnesses=[...new Set(group.records.map(harnessOf))];
      context.append(node('p','',`${models.length} model selections · ${harnesses.length} harnesses`));
      const tags=node('div','pa-tags');
      for (const label of (dimension.value==='model'?harnesses:models).slice(0,12)) tags.append(node('span','',label));
      context.append(tags);inspector.append(context);
      if (group.kind==='project') {
        const actions=node('div','pa-project-actions');
        const apply=node('button','button primary','Use project filter');apply.type='button';
        apply.addEventListener('click',()=>onProjectSelect(group.projectId));
        const isolate=node('button','button',focusProject===group.projectId?'Show all connections':'Isolate on canvas');isolate.type='button';
        isolate.addEventListener('click',()=>{focusProject=focusProject===group.projectId?'':group.projectId;draw();selectGroup(group);});
        actions.append(apply,isolate);inspector.append(actions);
      }
      inspector.append(node('h4','','Conversations in this group'));
      const list=node('div','pa-chat-list');
      for (const chat of [...group.records].sort((a,b)=>(b.total_tokens??-1)-(a.total_tokens??-1)).slice(0,30)) {
        const button=node('button','pa-chat item');button.type='button';
        button.append(node('span','',chat.title||'Untitled conversation'),node('small','',`${harnessOf(chat)} · ${modelOf(chat)} · ${fmt(messageCount(chat))} messages`));
        button.addEventListener('click',()=>onSelect(chat.id));list.append(button);
      }
      inspector.append(list);
      if (group.records.length>30) inspector.append(node('p','pa-note','Showing the 30 chats with the largest recorded counters in this group.'));
      highlight(group);
      if (activateProject && group.kind==='project') onProjectSelect(group.projectId);
    }
    function overviewInspector() {
      inspector.replaceChildren();
      inspector.append(node('span','pa-eyebrow','START WITH A PROJECT'),node('h3','','Follow your work'),
        node('p','pa-note','Select a project or model to inspect the conversations behind it. Lines and ribbons show chats recorded in that project, not semantic similarity.'));
      const directory=node('div','pa-project-directory');
      for (const project of [...projectGroups].sort((a,b)=>b.records.length-a.records.length||a.name.localeCompare(b.name))) {
        const button=node('button','pa-project item');button.type='button';
        button.append(node('span','',project.name),node('small','',`${number.format(project.records.length)} chats · ${fmt(sumKnown(project.records,messageCount))} messages`));
        button.addEventListener('click',()=>selectGroup(project));directory.append(button);
      }
      inspector.append(directory);
    }
    function highlight(group) {
      const memberIds=new Set(group.records.map((chat)=>chat.id));
      d3.select(canvas).selectAll('.pa-graph-node').classed('pa-dim',(datum)=>!datum.records.some((chat)=>memberIds.has(chat.id)));
      d3.select(canvas).selectAll('.pa-network-link').classed('pa-dim',(datum)=>!datum.records.some((chat)=>memberIds.has(chat.id)));
      d3.select(canvas).selectAll('.pa-chord-ribbon').classed('pa-dim',(datum)=>!datum.records.some((chat)=>memberIds.has(chat.id)));
      d3.select(canvas).selectAll('.pa-chord-group').classed('pa-dim',(datum)=>!datum.node.records.some((chat)=>memberIds.has(chat.id)));
    }
    function keyboard(selection, action) {
      selection.attr('tabindex',0).attr('role','button')
        .on('keydown',(event,datum)=>{if(event.key==='Enter'||event.key===' '){event.preventDefault();action(datum);}});
    }
    function data(limitProjects,limitCategories) {
      const picked=projectGroups.filter((project)=>!focusProject||project.projectId===focusProject)
        .sort((a,b)=>(metric(b.records)??-1)-(metric(a.records)??-1)||b.records.length-a.records.length).slice(0,limitProjects);
      const records=picked.flatMap((project)=>project.records);
      const categories=d3.rollups(records,(members)=>metric(members),categoryOf).sort((a,b)=>(b[1]??-1)-(a[1]??-1));
      const names=categories.slice(0,limitCategories).map(([name])=>name);
      const rest=new Set(categories.slice(limitCategories).map(([name])=>name));
      const categoryKey=(chat)=>rest.has(categoryOf(chat))?'__other_categories__':categoryOf(chat);
      const ends=[...names,...(rest.size?['__other_categories__']:[])].map((name,index)=>({id:`category:${name}`,kind:'category',name:name==='__other_categories__'?`Other ${dimension.value==='model'?'models':'harnesses'} (${rest.size})`:name,records:records.filter((chat)=>categoryKey(chat)===name),color:color(index)}));
      const links=[];
      for (const project of picked) for (const category of ends) {
        const members=project.records.filter((chat)=>categoryKey(chat)===category.id.slice(9));
        if (members.length) links.push({source:project.id,target:category.id,records:members,value:metric(members)});
      }
      return {nodes:[...picked,...ends],links,projects:picked,categories:ends,omitted:projectGroups.length-picked.length,records};
    }
    function setupSvg(width,height,label) {
      return d3.select(canvas).append('svg').attr('viewBox',`0 0 ${width} ${height}`).attr('width',width).attr('height',height)
        .attr('role','img').attr('aria-label',label);
    }
    function drawNetwork(width,height) {
      const graph=data(45,24);
      const svg=setupSvg(width,height,'Project network. Project nodes connect to models or harnesses recorded in their conversations.');
      const view=svg.append('g');
      const background=view.append('g').attr('class','pa-network-links');
      const max=d3.max(graph.nodes,(item)=>metric(item.records))||1;
      const radius=d3.scaleSqrt([0,max],[6,29]);
      const graphNodes=graph.nodes.map((item,index)=>({...item,index,radius:radius(metric(item.records)||0),x:width/2+(item.kind==='project'?-1:1)*width*.2,y:height/2+Math.sin(index*2.4)*height*.3}));
      const links=graph.links.map((link)=>({...link}));
      const maxLink=d3.max(links,(link)=>link.value)||1;
      const stroke=d3.scaleSqrt([0,maxLink],[.6,7]);
      const paths=background.selectAll('path').data(links).join('path').attr('class','pa-network-link')
        .attr('stroke-width',(link)=>stroke(link.value||0)).attr('fill','none');
      paths.on('mouseenter',(_,link)=>showTooltip([`${number.format(link.records.length)} chats connect this project and ${dimension.value}`,`${fmt(link.value)} ${metricName()}`]))
        .on('mouseleave',()=>{tooltip.hidden=true;}).on('click',(_,link)=>selectGroup({kind:'category',name:`Project / ${dimension.value} connection`,records:link.records}));
      const nodes=view.append('g').selectAll('g').data(graphNodes).join('g').attr('class','pa-graph-node');
      nodes.filter((item)=>item.kind==='project').append('rect').attr('class','pa-node-core pa-node-project')
        .attr('x',(item)=>-item.radius*.89).attr('y',(item)=>-item.radius*.89).attr('width',(item)=>item.radius*1.78).attr('height',(item)=>item.radius*1.78);
      nodes.filter((item)=>item.kind!=='project').append('circle').attr('class','pa-node-core').attr('r',(item)=>item.radius)
        .attr('fill',(item)=>item.color).attr('stroke',(item)=>item.color);
      nodes.append('text').attr('class','pa-node-label').attr('text-anchor','middle').attr('y',(item)=>item.radius+17)
        .text((item)=>item.name.length>27?item.name.slice(0,26)+'…':item.name);
      nodes.append('text').attr('class','pa-node-value').attr('text-anchor','middle').attr('y',(item)=>item.radius+31).text((item)=>`${fmt(metric(item.records))} ${measure.value==='chats'?'chats':measure.value}`);
      nodes.attr('aria-label',(item)=>groupInfo(item).join('. '))
        .on('mouseenter',(_,item)=>showTooltip(groupInfo(item))).on('mouseleave',()=>{tooltip.hidden=true;})
        .on('click',(event,item)=>{if(!event.defaultPrevented)selectGroup(item);})
        .on('dblclick',(event,item)=>{event.preventDefault();selectGroup(item,true);});
      keyboard(nodes,(item)=>selectGroup(item));
      const simulation=d3.forceSimulation(graphNodes).randomSource(d3.randomLcg(.41))
        .force('link',d3.forceLink(links).id((item)=>item.id).distance((link)=>105+link.source.radius+link.target.radius).strength(.22))
        .force('charge',d3.forceManyBody().strength((item)=>item.kind==='project'?-250:-360))
        .force('collide',d3.forceCollide((item)=>item.radius+25).strength(.9))
        .force('x',d3.forceX((item)=>width*(item.kind==='project'?.39:.64)).strength(.035))
        .force('y',d3.forceY(height/2).strength(.045)).stop();
      for (let tick=0;tick<180;tick++) simulation.tick();
      function paint() {
        nodes.attr('transform',(item)=>`translate(${item.x},${item.y})`);
        paths.attr('d',(link)=>`M${link.source.x},${link.source.y} Q${(link.source.x+link.target.x)/2},${(link.source.y+link.target.y)/2-25} ${link.target.x},${link.target.y}`);
      }
      paint();
      const zoom=d3.zoom().scaleExtent([.15,6]).on('zoom',(event)=>view.attr('transform',event.transform));
      svg.call(zoom).on('dblclick.zoom',null);
      function fit() {
        const bounds=view.node().getBBox();
        const scale=Math.min(1.5,(width-80)/Math.max(1,bounds.width),(height-90)/Math.max(1,bounds.height));
        svg.call(zoom.transform,d3.zoomIdentity.translate(width/2-(bounds.x+bounds.width/2)*scale,height/2-(bounds.y+bounds.height/2)*scale).scale(scale));
      }
      fit();
      nodes.call(d3.drag().on('start',(event,item)=>{event.sourceEvent.stopPropagation();item.fx=item.x;item.fy=item.y;simulation.alpha(.15).restart();})
        .on('drag',(event,item)=>{item.fx=event.x;item.fy=event.y;})
        .on('end',(_,item)=>{item.fx=null;item.fy=null;simulation.alphaTarget(0);}));
      simulation.on('tick',paint);
      reset.onclick=()=>{focusProject='';selected=null;draw();};
      zoomHint.textContent='Drag nodes · pan canvas · scroll to zoom · double-click a project to filter';
      status.textContent=`${graph.projects.length} projects · ${graph.categories.length} ${dimension.value==='model'?'model groups':'harness groups'} · ${links.length} observed connections${graph.omitted?` · ${graph.omitted} projects ${focusProject?'outside this isolated selection':'outside this canvas limit'}`:''}`;
      cleanupChart=()=>{simulation.stop();svg.on('.zoom',null);};
    }
    function drawChord(width,height) {
      const graph=data(18,12);
      const knownNodes=new Set(graph.links.filter((link)=>(link.value||0)>0).flatMap((link)=>[link.source,link.target]));
      const excludedNodes=graph.nodes.length-knownNodes.size;
      graph.nodes=graph.nodes.filter((item)=>knownNodes.has(item.id));
      const size=Math.min(width,height),outer=Math.max(90,size/2-(width<600?82:118)),inner=outer-15;
      const index=new Map(graph.nodes.map((item,i)=>[item.id,i]));
      const matrix=graph.nodes.map(()=>graph.nodes.map(()=>0));
      const memberships=new Map();
      for (const link of graph.links) {
        if (!(link.value>0)) continue;
        const a=index.get(link.source),b=index.get(link.target);
        matrix[a][b]=matrix[b][a]=Math.max(0,link.value||0);
        memberships.set(`${Math.min(a,b)}:${Math.max(a,b)}`,link.records);
      }
      const total=d3.sum(matrix,(row)=>d3.sum(row));
      if (!total) {
        canvas.append(node('div','pa-empty',`No positive measured ${metricName()} to draw ribbons. Try Conversation count or another selection.`));
        return;
      }
      const chords=d3.chord().padAngle(Math.min(.055,1/Math.max(1,graph.nodes.length))).sortSubgroups(d3.descending)(matrix);
      const svg=setupSvg(width,height,'Chord diagram of recorded project memberships. Ribbons connect projects to models or harnesses used in their conversations.');
      const graphic=svg.append('g').attr('transform',`translate(${width/2},${height/2})`);
      const arc=d3.arc().innerRadius(inner).outerRadius(outer);
      const groups=graphic.append('g').selectAll('g').data(chords.groups.map((group)=>({...group,node:graph.nodes[group.index]}))).join('g').attr('class','pa-chord-group');
      groups.append('path').attr('d',arc).attr('class',(group)=>group.node.kind==='project'?'pa-chord-project':null).attr('fill',(group)=>group.node.kind==='project'?null:group.node.color);
      groups.append('text').attr('dy','.35em').attr('transform',(group)=>{const angle=(group.startAngle+group.endAngle)/2;return `rotate(${angle*180/Math.PI-90}) translate(${outer+12}) ${angle>Math.PI?'rotate(180)':''}`;})
        .attr('text-anchor',(group)=>(group.startAngle+group.endAngle)/2>Math.PI?'end':'start')
        .text((group)=>{const limit=width<600?13:24;return group.node.name.length>limit?group.node.name.slice(0,limit-1)+'…':group.node.name;});
      groups.attr('aria-label',(group)=>groupInfo(group.node).join('. ')).on('mouseenter',(_,group)=>showTooltip(groupInfo(group.node)))
        .on('mouseleave',()=>{tooltip.hidden=true;}).on('click',(_,group)=>selectGroup(group.node));
      keyboard(groups,(group)=>selectGroup(group.node));
      const ribbons=graphic.append('g').selectAll('path').data(chords.map((chord)=>({...chord,records:memberships.get(`${Math.min(chord.source.index,chord.target.index)}:${Math.max(chord.source.index,chord.target.index)}`)||[]}))).join('path')
        .attr('class','pa-chord-ribbon').attr('d',d3.ribbon().radius(inner-3)).attr('fill',(chord)=>{
          const category=graph.nodes[chord.source.index].kind==='category'?graph.nodes[chord.source.index]:graph.nodes[chord.target.index];return category.color||COLORS[0];});
      const ribbonInfo=(chord)=>[`${graph.nodes[chord.source.index].name} ↔ ${graph.nodes[chord.target.index].name}`,`${fmt(chord.source.value)} ${metricName()} · ${chord.records.length} conversations`];
      const choose=(chord)=>selectGroup({kind:'category',name:`${graph.nodes[chord.source.index].name} / ${graph.nodes[chord.target.index].name}`,records:chord.records});
      ribbons.attr('aria-label',(chord)=>ribbonInfo(chord).join('. ')).on('mouseenter',(_,chord)=>showTooltip(ribbonInfo(chord)))
        .on('mouseleave',()=>{tooltip.hidden=true;}).on('click',(_,chord)=>choose(chord));
      keyboard(ribbons,choose);
      graphic.append('text').attr('class','pa-chord-center').attr('text-anchor','middle').attr('y',-5).text(fmt(metric(graph.records)));
      graphic.append('text').attr('class','pa-chord-center-label').attr('text-anchor','middle').attr('y',16).text(metricName());
      reset.onclick=()=>{selected=null;focusProject='';draw();};
      zoomHint.textContent='Select an arc or ribbon to inspect its conversations';
      status.textContent=`${graph.projects.length} projects · ${graph.categories.length} ${dimension.value==='model'?'model groups':'harness groups'} · ${graph.links.length} recorded memberships${excludedNodes?` · ${excludedNodes} groups without positive ${metricName()} excluded`:''}${graph.omitted?` · ${graph.omitted} projects ${focusProject?'outside this isolated selection':'outside this canvas limit'}`:''}`;
      cleanupChart=()=>{};
    }
    function draw() {
      if (closed) return;
      cleanupChart();cleanupChart=()=>{};
      canvas.replaceChildren();tooltip.hidden=true;
      for (const [key,button] of modeButtons) {button.classList.toggle('active',key===mode);button.setAttribute('aria-pressed',String(key===mode));}
      const width=Math.max(320,canvas.clientWidth||container.clientWidth||800),height=Math.max(480,canvas.clientHeight||600);
      lastWidth=width;lastHeight=height;
      summary.replaceChildren();
      for (const [label,value] of [['PROJECTS',projectGroups.length],['CONVERSATIONS',chats.length],['USER MESSAGES',sumKnown(chats,(chat)=>chat.user_messages)],['ASSISTANT MESSAGES',sumKnown(chats,(chat)=>chat.assistant_messages)]]) {
        const item=node('span');item.append(node('strong','',fmt(value)),node('small','',label));summary.append(item);
      }
      foot.textContent=`${measure.value==='tokens'?'Token widths use recorded lifetime totals; unknown counters do not create token-weighted ribbons. ':measure.value==='messages'?'Message widths use available conversation counts, which may cover partial local history. ':''}Projects use recorded project identity or workspace metadata. Connections show observed memberships, not topic similarity. Model edges use each chat’s recorded model selection. Display limits keep dense maps readable; use project filters for the complete selected group.`;
      if (!chats.length) canvas.append(node('div','pa-empty','No conversations match these filters. Select another project, model, harness, or date range.'));
      else if (mode==='network') drawNetwork(width,height);
      else drawChord(width,height);
      if (selected) selectGroup(selected);else overviewInspector();
    }
    measure.addEventListener('change',()=>{container.dataset.atlasMeasure=measure.value;draw();});
    dimension.addEventListener('change',()=>{container.dataset.atlasDimension=dimension.value;selected=null;draw();});
    const observer=new ResizeObserver(()=>{
      if (Math.abs(canvas.clientWidth-lastWidth)>1||Math.abs(canvas.clientHeight-lastHeight)>1) draw();
    });
    observer.observe(canvas);
    draw();
    return ()=>{closed=true;observer.disconnect();cleanupChart();root.remove();};
  }
  window.ProjectAtlas={render};
})();
