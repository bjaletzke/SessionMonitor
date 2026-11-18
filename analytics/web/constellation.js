import * as THREE from './vendor/three.module.js';
import {OrbitControls} from './vendor/three.OrbitControls.js';

const MAX_NODES = 600;
const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
const count = new Intl.NumberFormat('en');
const compact = new Intl.NumberFormat('en', {notation:'compact', maximumFractionDigits:1});

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function hash(text) {
  let value = 2166136261;
  for (const char of String(text)) value = Math.imul(value ^ char.charCodeAt(0), 16777619);
  return value >>> 0;
}

function tokens(chat) {
  return Number.isFinite(chat.total_tokens) && chat.total_tokens >= 0 ? chat.total_tokens : null;
}

/**
 * Explore explicit chat relationships in model or harness clusters.
 * Positions express grouping only. Distance is not semantic similarity.
 * Nothing animates in the background; the scene renders on user interaction.
 */
export function renderConstellation(container, {chats = [], relationships = [], onSelect = () => {}} = {}) {
  const all = [...chats].sort((a,b) => (tokens(b) ?? -1) - (tokens(a) ?? -1) || String(a.id).localeCompare(String(b.id)));
  const selected = all.slice(0, MAX_NODES);
  const COLORS = [1,2,3,4,5,6,7,8].map((i) => cssVar(`--series-${i}`));
  const root = element('article', 'constellation');
  const heading = element('div', 'constellation-heading');
  const actions = element('div', 'constellation-actions');
  const groupLabel = element('label', 'constellation-group-label field inline');
  groupLabel.append(element('span', '', 'Group by'));
  const groupSelect = element('select');
  groupSelect.setAttribute('aria-label', 'Constellation grouping');
  for (const [value,label] of [['project','Project'],['model','Model'],['harness','Harness']]) {
    const option = element('option', '', label); option.value=value; groupSelect.append(option);
  }
  groupSelect.value = ['project','model','harness'].includes(container.dataset.constellationGroup) ? container.dataset.constellationGroup : 'project';
  groupLabel.append(groupSelect);
  const reset = element('button', 'button', 'Reset camera');
  reset.type = 'button';
  actions.append(groupLabel,reset);
  const stage = element('div', 'constellation-stage');
  const labelLayer = element('div', 'constellation-labels');
  const tooltip = element('div', 'constellation-tooltip readout');
  tooltip.hidden = true;
  const caption = element('div', 'constellation-caption');
  const visibleCount = element('span', '', selected.length < all.length ? `Showing ${count.format(selected.length)} of ${count.format(all.length)} chats · largest recorded counters first` : `${count.format(selected.length)} conversations in this selection`);
  caption.append(visibleCount, element('span', '', 'Drag to orbit · scroll to zoom · right-drag to pan'));
  const note = element('p', 'constellation-note', 'Size uses a clamped logarithmic scale of recorded lifetime tokens. Unknown counters use the minimum size. Lines show explicit relationships only. Cluster position does not imply topic similarity.');
  const directory = element('details', 'constellation-directory');
  directory.append(element('summary', '', `Browse these ${count.format(selected.length)} conversations as a list`));
  const list = element('div', 'constellation-list');
  for (const chat of selected) {
    const button = element('button', 'constellation-chat item');
    button.type = 'button';
    button.append(element('span','',chat.title || 'Untitled conversation'),
      element('small','',`${chat.project_name || 'Unknown project'} · ${chat.model || 'Unknown model'} · ${chat.app || chat.connection_id || 'Unknown harness'} · ${tokens(chat) == null ? 'Unknown tokens' : `${compact.format(tokens(chat))} tokens`}`));
    button.addEventListener('click', () => onSelect(chat.id));
    list.append(button);
  }
  directory.append(list);
  heading.append(caption,actions);
  root.append(heading,stage,note,directory);
  container.replaceChildren(root);
  if (!selected.length) {
    stage.append(element('div','constellation-fallback','No conversations match these filters. Try another model, harness, or date range.'));
    reset.disabled = true;
    groupSelect.disabled = true;
    return () => root.remove();
  }

  let renderer;
  try {
    renderer = new THREE.WebGLRenderer({antialias:true, alpha:false, powerPreference:'low-power'});
  } catch {
    stage.append(element('div','constellation-fallback','The 3D view needs WebGL 2. You can still explore every conversation in the list below.'));
    directory.open = true;
    reset.disabled = true;
    groupSelect.disabled = true;
    return () => root.remove();
  }
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5));
  renderer.setClearColor(cssVar('--bg'));
  renderer.domElement.className = 'constellation-canvas';
  renderer.domElement.setAttribute('aria-label','Interactive 3D chat constellation. Use the conversation list below for keyboard access.');
  renderer.domElement.setAttribute('role','img');
  stage.append(renderer.domElement,labelLayer,tooltip);
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(44,1,1,2000);
  camera.position.set(0,115,320);
  const controls = new OrbitControls(camera,renderer.domElement);
  controls.enableDamping = false;
  controls.minDistance = 70;
  controls.maxDistance = 850;
  controls.enablePan = true;
  controls.zoomSpeed = 0.7;
  controls.rotateSpeed = 0.6;
  controls.target.set(0,0,0);
  controls.update();
  controls.saveState();
  const ambient = new THREE.HemisphereLight('#e1fff2','#214d43',2.1);
  scene.add(ambient);
  const light = new THREE.DirectionalLight('#eafff5',2.3);
  light.position.set(-50,120,180);
  scene.add(light);
  const geometry = new THREE.IcosahedronGeometry(1,2);
  const material = new THREE.MeshStandardMaterial({roughness:0.65, metalness:0.12});
  const mesh = new THREE.InstancedMesh(geometry,material,selected.length);
  scene.add(mesh);
  const haloGeometry = new THREE.IcosahedronGeometry(1,2);
  const haloMaterial = new THREE.MeshBasicMaterial({color:cssVar('--amber'),wireframe:true,transparent:true,opacity:0.7,depthWrite:false});
  const halo = new THREE.Mesh(haloGeometry,haloMaterial);
  halo.visible = false;
  scene.add(halo);
  const lineMaterial = new THREE.LineBasicMaterial({color:cssVar('--text-2'),transparent:true,opacity:0.3});
  let lineGeometry = new THREE.BufferGeometry();
  const edges = new THREE.LineSegments(lineGeometry,lineMaterial);
  scene.add(edges);
  const positions = new Map();
  const radii = [];
  const labels = [];
  const dummy = new THREE.Object3D();
  const raycaster = new THREE.Raycaster();
  const pointer = new THREE.Vector2();
  const projected = new THREE.Vector3();
  let disposed = false;
  let frame = 0;
  let hovered = -1;
  let pointerDown = null;
  let fitted = false;

  function draw() {
    if (disposed) return;
    renderer.render(scene,camera);
    const width=stage.clientWidth, height=stage.clientHeight;
    for (const item of labels) {
      projected.copy(item.position).project(camera);
      item.node.hidden = projected.z > 1 || projected.z < -1;
      item.node.style.transform = `translate(${(projected.x * .5 + .5) * width}px,${(-projected.y * .5 + .5) * height}px) translate(-50%,-50%)`;
    }
  }

  function schedule() {
    if (!frame && !disposed) frame=requestAnimationFrame(() => {frame=0;draw();});
  }

  function resize() {
    const width=Math.max(1,stage.clientWidth), height=Math.max(1,stage.clientHeight);
    renderer.setSize(width,height,false);
    camera.aspect=width/height;
    camera.updateProjectionMatrix();
    if (!fitted) {
      fitCamera();
      fitted=true;
    }
    schedule();
  }

  function fitCamera() {
    const radius=Math.max(45,...[...positions.values()].map((position) => position.length()+10));
    const vertical=THREE.MathUtils.degToRad(camera.fov);
    const horizontal=2*Math.atan(Math.tan(vertical/2)*camera.aspect);
    const distance=radius/Math.sin(Math.min(vertical,horizontal)/2)*1.08;
    camera.position.set(0,.27,1).normalize().multiplyScalar(distance);
    controls.target.set(0,0,0);
    controls.update();controls.saveState();
  }

  function layout() {
    const groupKey = (chat) => groupSelect.value === 'project' ? (chat.project_id || 'unknown') : groupSelect.value === 'harness' ? (chat.app || chat.connection_id || 'Unknown harness') : (chat.model || 'Unknown model');
    const rawGroups = new Map();
    for (const chat of selected) {
      const key=groupKey(chat);
      if (!rawGroups.has(key)) rawGroups.set(key,[]);
      rawGroups.get(key).push(chat);
    }
    const groups=[...rawGroups].sort((a,b) => b[1].length-a[1].length || a[0].localeCompare(b[0]));
    if (groups.length>12) groups.splice(11,groups.length-11,['Other groups',groups.slice(11).flatMap(([,members]) => members)]);
    const indices=new Map(selected.map((chat,index) => [chat.id,index]));
    positions.clear();
    labels.length=0;
    labelLayer.replaceChildren();
    const clusterDistance=groups.length===1 ? 0 : Math.min(112,65+groups.length*4);
    groups.forEach(([name,members],groupIndex) => {
      const angle=groupIndex/groups.length*Math.PI*2;
      const center=new THREE.Vector3(Math.cos(angle)*clusterDistance,Math.sin(angle*2)*15,Math.sin(angle)*clusterDistance*0.65);
      const spread=Math.min(52,15+Math.sqrt(members.length)*3.2);
      const label=element('div','constellation-cluster');
      const labelName=groupSelect.value === 'project' && name !== 'Other groups' ? (members[0].project_name || 'Unknown project') : name;
      label.title=groupSelect.value === 'project' ? (members[0].project_path || members[0].workspace || labelName) : labelName;
      label.append(element('strong','',labelName),element('small','',`${members.length} chats`));
      labelLayer.append(label);
      labels.push({node:label,position:center.clone().add(new THREE.Vector3(0,spread+12,0))});
      members.forEach((chat,memberIndex) => {
        const seed=hash(chat.id);
        const fraction=(memberIndex+.5)/members.length;
        const y=1-2*fraction;
        const spiral=memberIndex*2.399963229728653+(seed%200)/100;
        const radial=Math.sqrt(Math.max(0,1-y*y));
        const shell=0.48+(seed%100)/190;
        const position=new THREE.Vector3(Math.cos(spiral)*radial*spread*shell,y*spread*shell,Math.sin(spiral)*radial*spread*shell).add(center);
        const index=indices.get(chat.id);
        const value=tokens(chat);
        const radius=value==null ? 1.5 : Math.max(1.5,Math.min(5.2,1.15+Math.log10(1+value)*0.46));
        positions.set(chat.id,position);
        radii[index]=radius;
        dummy.position.copy(position);dummy.scale.setScalar(radius);dummy.updateMatrix();
        mesh.setMatrixAt(index,dummy.matrix);
        mesh.setColorAt(index,new THREE.Color(COLORS[groupIndex%COLORS.length]));
      });
    });
    mesh.instanceMatrix.needsUpdate=true;
    mesh.instanceColor.needsUpdate=true;
    mesh.computeBoundingSphere();
    const points=[];
    const seen=new Set();
    for (const relation of relationships) {
      const a=positions.get(relation.source_id),b=positions.get(relation.target_id);
      const key=[relation.source_id,relation.target_id].sort().join('\0');
      if (a && b && a!==b && !seen.has(key)) {points.push(a,b);seen.add(key);}
    }
    lineGeometry.dispose();
    lineGeometry=new THREE.BufferGeometry().setFromPoints(points);
    edges.geometry=lineGeometry;
    visibleCount.textContent=(selected.length<all.length ? `Showing ${selected.length} of ${count.format(all.length)} chats · largest counters first` : `${count.format(selected.length)} conversations`) + ` · ${count.format(points.length/2)} explicit links`;
    hover(-1);
    schedule();
  }

  function hover(index) {
    if (hovered===index) return;
    hovered=index;
    tooltip.replaceChildren();
    tooltip.hidden=index<0;
    halo.visible=index>=0;
    renderer.domElement.style.cursor=index>=0?'pointer':'grab';
    if (index>=0) {
      const chat=selected[index];
      tooltip.append(element('strong','',chat.title || 'Untitled conversation'),
        element('span','',`${chat.project_name || 'Unknown project'} · ${chat.model || 'Unknown model'} · ${chat.app || chat.connection_id || 'Unknown harness'}`),
        element('small','',tokens(chat)==null ? 'No recorded token counter' : `${count.format(tokens(chat))} recorded lifetime tokens`));
      halo.position.copy(positions.get(chat.id));
      halo.scale.setScalar(radii[index]*1.4);
    }
    schedule();
  }

  function hit(event) {
    const rect=renderer.domElement.getBoundingClientRect();
    pointer.set((event.clientX-rect.left)/rect.width*2-1,-((event.clientY-rect.top)/rect.height)*2+1);
    raycaster.setFromCamera(pointer,camera);
    return raycaster.intersectObject(mesh,false)[0]?.instanceId ?? -1;
  }
  function move(event) {if (!pointerDown) hover(hit(event));}
  function leave() {hover(-1);}
  function down(event) {pointerDown={x:event.clientX,y:event.clientY,button:event.button};}
  function up(event) {
    const start=pointerDown;pointerDown=null;
    if (start && start.button===0 && Math.hypot(start.x-event.clientX,start.y-event.clientY)<5) {
      const index=hit(event);
      if (index>=0) onSelect(selected[index].id);
    }
  }
  function cancel() {pointerDown=null;hover(-1);}
  function resetCamera() {fitCamera();hover(-1);schedule();}
  function regroup() {container.dataset.constellationGroup=groupSelect.value;layout();fitCamera();schedule();}
  function contextLost(event) {
    event.preventDefault();
    stage.hidden=true;
    caption.replaceChildren(element('span','','The graphics context was lost. Use the conversation list or reopen this view.'));
    directory.open=true;
  }
  renderer.domElement.addEventListener('pointermove',move);
  renderer.domElement.addEventListener('pointerleave',leave);
  renderer.domElement.addEventListener('pointerdown',down);
  renderer.domElement.addEventListener('pointerup',up);
  renderer.domElement.addEventListener('pointercancel',cancel);
  renderer.domElement.addEventListener('webglcontextlost',contextLost);
  controls.addEventListener('change',schedule);
  groupSelect.addEventListener('change',regroup);
  reset.addEventListener('click',resetCamera);
  const observer=new ResizeObserver(resize);
  observer.observe(stage);
  layout();resize();

  return () => {
    disposed=true;
    cancelAnimationFrame(frame);
    observer.disconnect();
    controls.removeEventListener('change',schedule);
    controls.dispose();
    renderer.domElement.removeEventListener('pointermove',move);
    renderer.domElement.removeEventListener('pointerleave',leave);
    renderer.domElement.removeEventListener('pointerdown',down);
    renderer.domElement.removeEventListener('pointerup',up);
    renderer.domElement.removeEventListener('pointercancel',cancel);
    renderer.domElement.removeEventListener('webglcontextlost',contextLost);
    groupSelect.removeEventListener('change',regroup);
    reset.removeEventListener('click',resetCamera);
    geometry.dispose();material.dispose();haloGeometry.dispose();haloMaterial.dispose();
    lineGeometry.dispose();lineMaterial.dispose();mesh.dispose();
    renderer.dispose();renderer.forceContextLoss();
    root.remove();
  };
}
