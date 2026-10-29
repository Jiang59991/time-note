(() => {
  'use strict';
  const $ = selector => document.querySelector(selector);
  const MINUTE = 60000;
  const defaultCats = {
    work: {name:'科研',color:'#bfdbfe',words:['论文','科研','实验','组会','文献','研究','数据分析','代码','编程','会议','开会']},
    create: {name:'自媒体',color:'#fecdd3',words:['自媒体','剪辑','剪视频','制作视频','拍视频','写文章','创作','拍摄','公众号','录播客']},
    move: {name:'运动',color:'#a7f3d0',words:['运动','攀岩','跑步','散步','健身','锻炼']},
    rest: {name:'娱乐',color:'#fde68a',words:['电影','游戏','娱乐','休息','刷手机','看视频','刷视频','看剧','听播客']},
    sleep: {name:'睡眠',color:'#d1d5db',words:['睡觉','睡眠','午睡','午休']},
    dining: {name:'餐饮',color:'#fed7aa',words:['餐饮','早餐','午餐','晚餐','早饭','午饭','晚饭','吃饭','用餐','夜宵']},
    daily: {name:'生活',color:'#d9f99d',words:['生活']},
    life: {name:'杂事',color:'#99f6e4',words:['做饭','买菜','通勤','咖啡','洗澡','家务','采购','快递']},
    other: {name:'其他',color:'#ddd6fe',words:['阅读','看书','学习','英语','课程','读书']}
  };
  let cats={...defaultCats}, categoryRows=Object.entries(cats).map(([id,c])=>({id,name:c.name,color:c.color,revision:0}));
  let categoryPalette=['#bfdbfe','#fecdd3','#a7f3d0','#fde68a','#c6c8cc','#fed7aa','#d9f99d','#99f6e4','#ddd6fe','#fbcfe8','#bae6fd','#e2e8f0'];
  let categoryEditing=null, categoryColor='#bfdbfe', categorySignature='';
  const dayNames = ['周日','周一','周二','周三','周四','周五','周六'];
  let records=[], todos={}, categoryMemory={}, revision=-1, ready=false;
  let view='day', selectedDate=dateKey(Date.now()), entryMode='timer', manualDateTouched=false;
  let newCategoryManual=false, editCategoryManual=false, editRecognition=false, editingBase=null, editingFingerprint='';
  let inFlight=false, retryCommand=null, statusTimer=null, confirmResolve=null;
  let peekAnchor=null, peekTimer=null, lastPomo=null, lastToday=selectedDate, lastMinute=Math.floor(Date.now()/MINUTE);
  let todoSignature='', runningSignature='';
  const now=()=>Date.now();
  function pad(n){return String(n).padStart(2,'0');}
  const clone=value=>JSON.parse(JSON.stringify(value));
  const normalizeTitle=title=>title.trim().normalize('NFC').toLowerCase();
  function dateKey(value){const d=new Date(value);return d.getFullYear()+'-'+pad(d.getMonth()+1)+'-'+pad(d.getDate());}
  function parts(key){const match=/^(\d{4})-(\d{2})-(\d{2})$/.exec(key||'');return match?match.slice(1).map(Number):null;}
  function dayStart(key){const p=parts(key);if(!p)return NaN;const d=new Date(p[0],p[1]-1,p[2]);return dateKey(d.getTime())===key?d.getTime():NaN;}
  function addDays(key,count){const p=parts(key);if(!p)return '';const d=new Date(p[0],p[1]-1,p[2]+count,12);return dateKey(d.getTime());}
  function dayEnd(key){return dayStart(addDays(key,1));}
  function weekStart(){const weekday=new Date(dayStart(selectedDate)).getDay();return addDays(selectedDate,-((weekday+6)%7));}
  function time(value){const d=new Date(value);return pad(d.getHours())+':'+pad(d.getMinutes());}
  function inputTime(value){return dateKey(value)+'T'+time(value);}
  function fullDate(key){return key.replaceAll('-','.');}
  function relativeDate(key){const today=dateKey(now());return key===today?'今天':key===addDays(today,-1)?'昨天':fullDate(key);}
  function parseTime(key,clock){const p=parts(key),m=/^(\d{2}):(\d{2})$/.exec(clock||'');if(!p||!m)return NaN;const d=new Date(p[0],p[1]-1,p[2],Number(m[1]),Number(m[2]));return dateKey(d.getTime())===key&&time(d.getTime())===clock?d.getTime():NaN;}
  function formTime(prefix,edge){return parseTime($('#'+prefix+'-'+edge+'-date').value,$('#'+prefix+'-'+edge).value);}
  function sameFormTime(prefix,edge,value){return Number.isFinite(value)&&$('#'+prefix+'-'+edge+'-date').value+'T'+$('#'+prefix+'-'+edge).value===inputTime(value);}
  function duration(ms){const m=Math.floor(Math.max(0,ms)/MINUTE);return m>=60?Math.floor(m/60)+'h'+(m%60?pad(m%60)+'m':''):m+'m';}
  function timerString(ms){const s=Math.floor(Math.max(0,ms)/1000);return s>=3600?Math.floor(s/3600)+':'+pad(Math.floor(s/60)%60)+':'+pad(s%60):pad(Math.floor(s/60))+':'+pad(s%60);}
  function element(tag,cls,text){const el=document.createElement(tag);if(cls)el.className=cls;if(text!==undefined)el.textContent=text;return el;}
  function guessCategory(title){const key=normalizeTitle(title);if(Object.hasOwn(categoryMemory,key)&&cats[categoryMemory[key]])return categoryMemory[key];if(cats.dining?.words.some(word=>key.includes(word)))return 'dining';for(const [id,c]of Object.entries(cats))if(c.words.some(word=>key.includes(word))||(id!=='other'&&key.includes(normalizeTitle(c.name))))return id;return 'other';}
  const running=()=>records.filter(r=>r.end===null).sort((a,b)=>a.start-b.start);
  const recordEnd=r=>r.end===null?(r.mode==='pomodoro'?Math.min(now(),r.deadline):now()):r.end;
  function rangeRecords(start,end){return records.filter(r=>r.start<end&&recordEnd(r)>start).map(record=>({record,start:Math.max(start,record.start),end:Math.min(end,recordEnd(record))})).filter(r=>r.end>r.start).sort((a,b)=>a.start-b.start||b.end-a.end);}
  function recordRangeLabel(r){const stop=recordEnd(r),a=dateKey(r.start),b=dateKey(stop),endLabel=r.end===null?(r.mode==='pomodoro'&&now()>=r.deadline?time(r.deadline):'现在'):time(stop);return a===b?relativeDate(a)+' '+time(r.start)+'–'+endLabel:fullDate(a)+' '+time(r.start)+' — '+fullDate(b)+' '+endLabel;}
  function recordDetail(r){const item=element('div','peek-entry');item.append(element('div','peek-title',r.title),element('div','peek-time',recordRangeLabel(r)),element('div','peek-meta',cats[r.category].name+' · '+duration(recordEnd(r)-r.start)));return item;}
  function say(text,error=false,persistent=false){if(statusTimer)clearTimeout(statusTimer);$('#status').textContent=text;$('#status').classList.toggle('error',error);if(!persistent)statusTimer=setTimeout(()=>{$('#status').textContent='';},5000);}
  function message(error){return error?.message||String(error||'操作失败，请重试。');}
  async function native(payload){const handler=window.webkit?.messageHandlers?.timeNote;if(!handler?.postMessage)throw new Error('原生连接不可用。请从“时间便签”应用打开。');const result=await handler.postMessage(payload);if(result?.error)throw new Error(result.error);return result;}
  function uuid(){if(crypto.randomUUID)return crypto.randomUUID();const bytes=crypto.getRandomValues(new Uint8Array(16));bytes[6]=(bytes[6]&15)|64;bytes[8]=(bytes[8]&63)|128;const h=[...bytes].map(v=>v.toString(16).padStart(2,'0'));return h.slice(0,4).join('')+'-'+h.slice(4,6).join('')+'-'+h.slice(6,8).join('')+'-'+h.slice(8,10).join('')+'-'+h.slice(10).join('');}
  function syncBusy(){
    for(const el of document.querySelectorAll('#entry-form input,#entry-form select,#entry-form button,#todo-form input,#todo-form button,#todo-list input,#todo-list button,#running-list button,#edit-form input,#edit-form select,#edit-form button,#category-form input,#category-form button,#category-list button'))el.disabled=inFlight||!ready;
    $('#category-name').disabled=inFlight||!ready||categoryEditing?.id==='other';
    if(editingBase){const current=records.find(r=>r.id===editingBase.id),stale=!current||current.revision!==editingBase.revision;for(const id of ['edit-save','edit-stop','edit-delete'])$('#'+id).disabled=inFlight||!ready||stale;$('#edit-reload').disabled=inFlight||!current;}
  }
  function receiveSnapshot(snapshot){
    if(!snapshot||snapshot.schemaVersion!==1||!Number.isInteger(snapshot.revision)||!Array.isArray(snapshot.records)||!snapshot.todos||!snapshot.categoryMemory)throw new Error('数据格式不受支持。');
    if(snapshot.revision<revision)return false;
    const nextRows=snapshot.categories||categoryRows;
    if(!Array.isArray(nextRows)||!nextRows.length||!nextRows.some(c=>c.id==='other')||!nextRows.every(c=>typeof c.id==='string'&&typeof c.name==='string'&&/^#[0-9a-f]{6}$/.test(c.color)&&Number.isSafeInteger(c.revision)))throw new Error('标签数据无效。');
    const nextCats=Object.fromEntries(nextRows.map(c=>[c.id,{...c,words:defaultCats[c.id]?.words||[]}]));
    if(!snapshot.records.every(r=>typeof r.id==='string'&&Object.hasOwn(nextCats,r.category)&&Number.isFinite(r.start)&&(r.end===null||Number.isFinite(r.end))))throw new Error('记录数据无效，请检查备份。');
    if(snapshot.revision===revision&&ready)return false;
    const before=records;
    const oldSelection={new:$('#new-category').value,edit:$('#edit-category').value};
    cats=nextCats;categoryRows=clone(nextRows);categoryPalette=snapshot.categoryPalette||categoryPalette;
    syncCategorySelectors(oldSelection);renderCategoryManager();
    records=clone(snapshot.records);todos=clone(snapshot.todos);categoryMemory=clone(snapshot.categoryMemory);revision=snapshot.revision;ready=true;
    $('#connection-error').hidden=true;
    for(const old of before){const changed=records.find(r=>r.id===old.id);if(old.end===null&&changed?.end!==null&&changed?.finishReason==='deadline')lastPomo=changed;}
    renderData();checkEditorConflict();syncBusy();return true;
  }
  async function mutate(type,fields,errorTarget){
    if(inFlight||!ready)return false;
    const body={type,...fields},fingerprint=JSON.stringify(body);
    const command=retryCommand?.fingerprint===fingerprint?retryCommand.command:{operationID:uuid(),...body};
    retryCommand={fingerprint,command};inFlight=true;syncBusy();if(errorTarget)$(errorTarget).textContent='';
    try{receiveSnapshot(await native({action:'command',command}));retryCommand=null;return true;}
    catch(error){const text=message(error);if(errorTarget)$(errorTarget).textContent=text;else say(text,true,true);try{receiveSnapshot(await native({action:'load'}));}catch{}return false;}
    finally{inFlight=false;syncBusy();}
  }
  async function load(){try{receiveSnapshot(await native({action:'load'}));}catch(error){$('#connection-error').textContent=message(error)+' 可从右上角菜单重新读取。';$('#connection-error').hidden=false;syncBusy();}}
  function confirmAction(text,label='确认'){if(confirmResolve)return Promise.resolve(false);$('#confirm-message').textContent=text;$('#confirm-ok').textContent=label;$('#confirm-dialog').showModal();return new Promise(resolve=>{confirmResolve=resolve;});}
  function settleConfirm(value){$('#confirm-dialog').close();const resolve=confirmResolve;confirmResolve=null;if(resolve)resolve(value);}
  function hidePeek(){if(peekTimer)clearTimeout(peekTimer);peekTimer=null;$('#time-peek').hidden=true;if(peekAnchor)peekAnchor.removeAttribute('aria-describedby');peekAnchor=null;}
  function showPeek(anchor,items){hidePeek();if(!items.length)return;const peek=$('#time-peek');items.forEach(r=>peek.append(recordDetail(r)));if(items.length>1)peek.prepend(element('div','peek-heading','同时进行 · '+items.length+' 项'));peek.hidden=false;peekAnchor=anchor;anchor.setAttribute('aria-describedby','time-peek');const rect=anchor.getBoundingClientRect(),box=peek.getBoundingClientRect();peek.style.left=Math.max(8,Math.min(innerWidth-box.width-8,rect.left+rect.width/2-box.width/2))+'px';peek.style.top=Math.max(8,rect.bottom+box.height+10<innerHeight?rect.bottom+7:rect.top-box.height-7)+'px';}
  function peek(anchor,items){$('#time-peek').replaceChildren();showPeek(anchor,items);}
  function openOverlap(items){hidePeek();$('#overlap-items').replaceChildren();for(const item of items){const button=element('button','overlap-choice');button.type='button';button.dataset.recordId=item.id;button.append(recordDetail(item));button.addEventListener('click',()=>{$('#overlap-picker').close();openEditor(item.id);});$('#overlap-items').append(button);}$('#overlap-picker').showModal();}
  function axis(target,date){target.replaceChildren();const start=dayStart(date),end=dayEnd(date),p=parts(date);for(const hour of [0,6,12,18,24]){const label=element('span','',pad(hour));const instant=hour===24?end:new Date(p[0],p[1]-1,p[2],hour).getTime();label.style.left=(instant-start)/(end-start)*100+'%';target.append(label);}}
  function makeTrack(date,compact=false,vertical=false){
    const start=dayStart(date),end=dayEnd(date),length=end-start,intervals=rangeRecords(start,end),track=element('div','track'+(compact?' compact':'')+(vertical?' vertical':''));track.dataset.date=date;
    const boundaries=[...new Set(intervals.flatMap(item=>[item.start,item.end]))].sort((a,b)=>a-b),until=Math.min(end,Math.max(start,now()));
    if(until<end){const future=element('div','future');future.style[vertical?'top':'left']=(until-start)/length*100+'%';track.append(future);}
    for(let i=0;i<boundaries.length-1;i++){
      const from=boundaries[i],to=boundaries[i+1],active=intervals.filter(item=>item.start<to&&item.end>from).map(item=>item.record);if(!active.length||to<=from)continue;
      const button=element('button','block'+(active.length>1?' overlapping':'')+(active.some(r=>r.end===null)?' running':''));button.type='button';button.dataset.recordIds=active.map(r=>r.id).join(',');button.dataset.start=from;button.dataset.end=to;button.style[vertical?'top':'left']=(from-start)/length*100+'%';button.style[vertical?'height':'width']=(to-from)/length*100+'%';
      const colors=active.map(r=>cats[r.category].color);button.style.setProperty('--tone',colors[0]);if(active.length>1){const stops=colors.flatMap((color,j)=>[(j%2?color:color+'b8')+' '+j*5+'px',(j%2?color:color+'b8')+' '+(j+1)*5+'px']);button.style.setProperty('--band-fill','repeating-linear-gradient(135deg,'+stops.join(',')+')');if(!compact)button.textContent='⋮';}else if(!compact&&to-from>100*MINUTE)button.textContent=active[0].title;
      button.setAttribute('aria-label',active.map(r=>r.title+'，'+recordRangeLabel(r)).join('；')+(active.length>1?'；选择事项':'；修改记录'));
      const currentItems=()=>button.dataset.recordIds.split(',').map(id=>records.find(r=>r.id===id)).filter(Boolean);
      button.addEventListener('pointerenter',()=>peek(button,currentItems()));button.addEventListener('pointerleave',()=>{peekTimer=setTimeout(hidePeek,130);});button.addEventListener('focus',()=>peek(button,currentItems()));button.addEventListener('blur',hidePeek);
      button.addEventListener('click',()=>{hidePeek();const items=currentItems();if(items.length===1)openEditor(items[0].id);else if(items.length>1)openOverlap(items);});track.append(button);
    }
    if(date===dateKey(now())){const line=element('i','now-line');line.style[vertical?'top':'left']=(now()-start)/length*100+'%';track.append(line);}return track;
  }
  function preserveTrackFocus(container,update){const focused=document.activeElement,block=container.contains(focused)&&focused.matches('.block,.day-label')?focused:null,saved=block?{selector:block.matches('.day-label')?'.day-label':'.block',date:block.closest('.track').dataset.date,ids:block.dataset.recordIds.split(','),start:Number(block.dataset.start)}:null;update();if(!saved)return;const choices=[...container.querySelectorAll(saved.selector)].filter(el=>el.closest('.track').dataset.date===saved.date&&el.dataset.recordIds.split(',').some(id=>saved.ids.includes(id)));choices.sort((a,b)=>{const exact=el=>el.dataset.recordIds.split(',').length===saved.ids.length&&saved.ids.every(id=>el.dataset.recordIds.split(',').includes(id));return Number(exact(b))-Number(exact(a))||Math.abs(Number(a.dataset.start)-saved.start)-Math.abs(Number(b.dataset.start)-saved.start);});if(choices[0])choices[0].focus({preventScroll:true});else hidePeek();}
  function makeDayTrack(date){
    const start=dayStart(date),end=dayEnd(date),length=end-start,track=element('div','track day-multitrack');track.dataset.date=date;
    const items=rangeRecords(start,end).sort((a,b)=>a.start-b.start||b.end-a.end||a.record.id.localeCompare(b.record.id)),lanes=[];
    if(!items.length)track.append(element('div','day-empty','这一天还没有时间记录。'));
    for(const item of items){
      let lane=lanes.find(lane=>lane.end<=item.start);
      if(!lane){const row=element('div','day-lane'),band=element('div','day-band');row.append(band);track.append(row);lane={end:start,band};lanes.push(lane);
        if(date===dateKey(now())){const line=element('i','now-line');line.style.left=(now()-start)/length*100+'%';band.append(line);}
      }
      lane.end=item.end;
      const r=item.record,button=element('button','block'+(r.end===null?' running':''),r.title);button.type='button';button.dataset.recordIds=r.id;button.dataset.start=item.start;button.dataset.end=item.end;button.style.left=(item.start-start)/length*100+'%';button.style.width=(item.end-item.start)/length*100+'%';button.style.setProperty('--tone',cats[r.category].color);button.setAttribute('aria-label',r.title+'，'+recordRangeLabel(r)+'；修改记录');
      const show=()=>{const current=records.find(x=>x.id===r.id);if(current)peek(button,[current]);};
      button.addEventListener('click',()=>{hidePeek();openEditor(r.id);});button.addEventListener('pointerenter',show);button.addEventListener('pointerleave',hidePeek);button.addEventListener('focus',show);button.addEventListener('blur',hidePeek);lane.band.append(button);
    }
    return track;
  }
  function renderDay(){axis($('#day-axis'),selectedDate);preserveTrackFocus($('#day-track'),()=>$('#day-track').replaceChildren(makeDayTrack(selectedDate)));renderTodos();}
  function renderWeek(){const startKey=weekStart(),start=dayStart(startKey),end=dayStart(addDays(startKey,7));$('#week-axis').replaceChildren();for(let hour=0;hour<=24;hour+=3){const label=element('span','',pad(hour));label.style.top=hour/24*100+'%';$('#week-axis').append(label);}preserveTrackFocus($('#week-days'),()=>{$('#week-days').replaceChildren();for(let i=0;i<7;i++){const date=addDays(startKey,i),d=new Date(dayStart(date)),row=element('div','week-row'+(date===dateKey(now())?' today':'')),button=element('button','week-date',dayNames[d.getDay()]);button.type='button';button.append(element('span','',d.getDate()));button.setAttribute('aria-label','查看 '+date+' 日览');button.addEventListener('click',()=>{selectedDate=date;chooseView('day');});row.append(button,makeTrack(date,false,true));$('#week-days').append(row);}});
    const totals=Object.fromEntries(Object.keys(cats).map(key=>[key,0]));rangeRecords(start,end).forEach(item=>totals[item.record.category]+=item.end-item.start);const max=Math.max(1,...Object.values(totals));$('#category-summary').replaceChildren();for(const [id,cat]of Object.entries(cats)){const cell=element('div','category-cell');cell.dataset.category=id;cell.dataset.duration=totals[id];cell.style.setProperty('--tone',cat.color);const label=element('span');label.append(element('i'),document.createTextNode(cat.name));const bar=element('div','cat-bar');bar.style.width=totals[id]/max*100+'%';cell.append(label,element('span','cat-time',duration(totals[id])),bar);$('#category-summary').append(cell);}}
  function syncCategorySelectors(selected){
    const signature=JSON.stringify(categoryRows);if(signature===categorySignature)return;categorySignature=signature;runningSignature='';hidePeek();
    for(const prefix of ['new','edit']){const select=$('#'+prefix+'-category');select.replaceChildren();for(const c of categoryRows){const option=element('option','',c.name);option.value=c.id;select.append(option);}select.value=Object.hasOwn(cats,selected[prefix])?selected[prefix]:'other';}
  }
  function renderCategoryPalette(){
    $('#category-palette').replaceChildren();for(const color of categoryPalette){const button=element('button','category-swatch');button.type='button';button.style.setProperty('--swatch',color);button.dataset.color=color;button.setAttribute('role','radio');button.setAttribute('aria-label','颜色 '+color);button.setAttribute('aria-checked',String(categoryColor===color));button.addEventListener('click',()=>{categoryColor=color;for(const b of $('#category-palette').children)b.setAttribute('aria-checked',String(b.dataset.color===color));});$('#category-palette').append(button);}
  }
  function resetCategoryForm(){categoryEditing=null;categoryColor=categoryPalette[0];$('#category-name').value='';$('#category-save').textContent='新增标签';$('#category-reset').hidden=true;$('#category-error').textContent='';renderCategoryPalette();syncBusy();}
  function renderCategoryManager(){
    if(!$('#category-manager').open)return;
    const list=$('#category-list'),signature=JSON.stringify(categoryRows);if(list.dataset.signature===signature)return;list.dataset.signature=signature;list.replaceChildren();
    for(const c of categoryRows){const row=element('div','category-manager-row'),dot=element('i','category-dot');dot.style.background=c.color;const name=element('span','category-name',c.name),edit=element('button','','修改');edit.type='button';edit.setAttribute('aria-label','修改标签 '+c.name);edit.addEventListener('click',()=>{categoryEditing={...c};categoryColor=c.color;$('#category-name').value=c.name;$('#category-save').textContent='保存标签';$('#category-reset').hidden=false;$('#category-error').textContent='';renderCategoryPalette();syncBusy();if(c.id!=='other')$('#category-name').focus();});row.append(dot,name,edit);if(c.id!=='other'){const remove=element('button','category-remove','删除');remove.type='button';remove.setAttribute('aria-label','删除标签 '+c.name);remove.addEventListener('click',async()=>{if(await confirmAction('删除标签“'+c.name+'”？使用它的记录将归到“其他”，时间记录不会删除。','删除标签')){if(await mutate('categoryDelete',{id:c.id,expectedRevision:c.revision},'#category-error')){if(categoryEditing?.id===c.id)resetCategoryForm();}}});row.append(remove);}else row.append(element('span','category-fallback','兜底标签'));list.append(row);}syncBusy();
  }
  function openCategoryManager(){if(inFlight||!ready)return;$('#tools-menu').hidden=true;$('#tools-toggle').setAttribute('aria-expanded','false');$('#category-manager').showModal();resetCategoryForm();renderCategoryManager();$('#category-name').focus();}
  function renderTodos(){const list=todos[selectedDate]||[],signature=selectedDate+JSON.stringify(list);if(signature===todoSignature)return;todoSignature=signature;const focused=document.activeElement,row=focused.closest?.('[data-todo-id]'),focus=row?{id:row.dataset.todoId,tag:focused.tagName.toLowerCase()}:null;$('#todo-list').replaceChildren();for(const todo of list){const row=element('div','todo-row'+(todo.done?' done':''));row.dataset.todoId=todo.id;const check=element('input');check.type='checkbox';check.checked=todo.done;check.setAttribute('aria-label','完成 '+todo.title);check.addEventListener('change',async()=>{const done=check.checked;check.checked=todo.done;await mutate('todoSet',{day:selectedDate,id:todo.id,expectedRevision:todo.revision,done});});const title=element('span','todo-title',todo.title),remove=element('button','','×');remove.type='button';remove.setAttribute('aria-label','删除待办 '+todo.title);remove.addEventListener('click',async()=>{const day=selectedDate;if(await confirmAction('删除待办“'+todo.title+'”？','删除'))await mutate('todoDelete',{day,id:todo.id,expectedRevision:todo.revision});});row.append(check,title,remove);$('#todo-list').append(row);}if(focus){const row=[...$('#todo-list').children].find(el=>el.dataset.todoId===focus.id);row?.querySelector(focus.tag)?.focus({preventScroll:true});}syncBusy();}
  function renderRunning(){const active=running(),signature=JSON.stringify(active);if(signature!==runningSignature){runningSignature=signature;const focused=document.activeElement,card=focused.closest?.('[data-task-id]'),focus=card?{id:card.dataset.taskId,stop:focused.classList.contains('stop')}:null;$('#running-list').replaceChildren();if(!active.length)$('#running-list').append(element('p','running-empty','现在没有计时中的事项。可以安静地开始下一件事。'));for(const r of active){const card=element('article','running-card');card.dataset.taskId=r.id;const left=element('div'),title=element('button','running-title',r.title);title.type='button';title.addEventListener('click',()=>openEditor(r.id));const meta=element('div','running-meta');meta.append(element('span','mono',relativeDate(dateKey(r.start))+' '+time(r.start)+' 开始'),document.createTextNode(' · '+cats[r.category].name));left.append(title,meta);const right=element('div','running-right'),clock=element('span','running-clock'),stop=element('button','stop','结束');clock.dataset.clockId=r.id;stop.type='button';stop.dataset.stopId=r.id;stop.setAttribute('aria-label','结束 '+r.title+'（'+time(r.start)+' 开始）');stop.addEventListener('click',async()=>{if(await mutate('finish',{id:r.id,expectedRevision:r.revision}))say('已结束“'+r.title+'”。');});right.append(clock,stop);card.append(left,right);$('#running-list').append(card);}if(focus){const card=[...$('#running-list').children].find(el=>el.dataset.taskId===focus.id);card?.querySelector(focus.stop?'.stop':'.running-title')?.focus({preventScroll:true});}}
    $('#running-heading').textContent='进行中 · '+active.length;$('#pomo-notice').hidden=!lastPomo;if(lastPomo){$('#pomo-notice').replaceChildren(document.createTextNode('“'+lastPomo.title+'” 本轮已结束。 '));const button=element('button','new-round','准备下一轮');button.type='button';button.addEventListener('click',()=>{if(inFlight)return;$('#new-title').value=lastPomo.title;$('#new-category').value=lastPomo.category;newCategoryManual=lastPomo.categoryManual;$('#new-timer-mode').value='pomodoro';$('#new-minutes').value=lastPomo.minutes;updateEntryMode('timer');updateTimerMode();updateCategory('new');$('#new-title').focus();});$('#pomo-notice').append(button);}renderClocks();syncBusy();}
  function renderDate(){const d=new Date(dayStart(selectedDate));$('#date-label').textContent=view==='week'?fullDate(weekStart())+' — '+fullDate(addDays(weekStart(),6)).slice(5):view==='record'?relativeDate(dateKey(now()))+' · '+fullDate(dateKey(now())):fullDate(selectedDate)+' · '+dayNames[d.getDay()];$('#prev-date').hidden=view==='record';$('#next-date').hidden=view==='record';}
  function renderData(){renderDate();renderClocks();if(view==='day')renderDay();if(view==='week')renderWeek();if(view==='record')renderRunning();syncBusy();}
  function chooseView(next){hidePeek();view=next;$('#sheet').dataset.view=view;for(const id of ['day','week','record']){$('#view-'+id).hidden=id!==view;$('#tab-'+id).setAttribute('aria-selected',String(id===view));$('#tab-'+id).tabIndex=id===view?0:-1;}renderData();native({action:'view',view}).catch(error=>say(message(error),true,true));}
  function renderClocks(){refreshManualDate();$('#clock-label').textContent=time(now());$('#activity-count').textContent=ready?'进行中 '+running().length:'正在读取…';for(const el of document.querySelectorAll('[data-clock-id]')){const r=records.find(r=>r.id===el.dataset.clockId);if(!r)continue;el.textContent=r.mode==='pomodoro'?(now()>=r.deadline?'到时结算中':'余 '+timerString(r.deadline-now())):timerString(now()-r.start);}}
  function syncDateSummary(prefix){const start=$('#'+prefix+'-start-date').value,end=$('#'+prefix+'-end-date').value;$('#'+prefix+'-date-summary').textContent=!start||!end?'请填写日期':start===end?relativeDate(start):fullDate(start)+' — '+fullDate(end);$('#'+prefix+'-next-day').checked=Number.isFinite(dayStart(start))&&end===addDays(start,1);}
  function resetManualTimes(){manualDateTouched=false;const today=dateKey(now());$('#new-start').value='';$('#new-end').value='';$('#new-start-date').value=today;$('#new-end-date').value=today;$('#new-start-date').dataset.previous=today;$('#new-date-fields').hidden=true;$('#new-date-toggle').setAttribute('aria-expanded','false');syncDateSummary('new');}
  function refreshManualDate(){if(entryMode!=='manual')return;const empty=!$('#new-start').value&&!$('#new-end').value;if(!manualDateTouched&&empty&&$('#new-start-date').value!==dateKey(now()))resetManualTimes();else syncDateSummary('new');}
  function updateCategory(prefix){const manual=prefix==='new'?newCategoryManual:editCategoryManual,title=$('#'+prefix+'-title').value;if(!manual&&prefix==='new')$('#new-category').value=guessCategory(title);const remembered=Object.hasOwn(categoryMemory,normalizeTitle(title));$('#'+prefix+'-category-status').textContent=manual?'已手动指定':prefix==='edit'?(editRecognition?'已重新识别':'保留当前分类'):remembered?'使用记忆分类':$('#'+prefix+'-category').value==='other'?'归入其他 · 可修改':'自动识别';$('#'+prefix+'-category-reset').hidden=prefix==='new'&&!manual;if(prefix==='edit')$('#edit-category-reset').textContent='重新识别';}
  function updateTimerMode(){$('#minutes-field').hidden=$('#new-timer-mode').value!=='pomodoro';}
  function updateEntryMode(mode){entryMode=mode;refreshManualDate();for(const button of document.querySelectorAll('[data-entry-mode]'))button.setAttribute('aria-pressed',String(button.dataset.entryMode===mode));$('#timer-fields').hidden=mode!=='timer';$('#manual-fields').hidden=mode!=='manual';$('#entry-submit').textContent=mode==='timer'?'开始计时':'添加记录';$('#entry-hint').innerHTML=mode==='timer'?'已有事项会继续计时。<br>每一项都有自己的结束按钮。':'允许跨日与时间重叠。<br>填好起止时间即可补记。';$('#entry-error').textContent='';}
  function validRange(start,end){if(!Number.isFinite(start)||!Number.isFinite(end))return '请填写有效的开始与结束时间；夏令时跳过的时刻不能使用。';if(end<=start)return '结束时间必须晚于开始时间；跨日请明确修改日期。';if(end>now())return '结束时间不能晚于当前时刻。';return '';}
  async function startOrAdd(event){event.preventDefault();if(inFlight||!ready)return;const title=$('#new-title').value.trim()||'未命名事项',category=$('#new-category').value,base={title,category,categoryManual:newCategoryManual};let type,fields;if(entryMode==='manual'){const start=formTime('new','start'),end=formTime('new','end'),error=validRange(start,end);if(error){$('#entry-error').textContent=error;return;}type='manual';fields={...base,start,end};}else{const mode=$('#new-timer-mode').value,minutes=Number($('#new-minutes').value);if(mode==='pomodoro'&&(!Number.isInteger(minutes)||minutes<1||minutes>240)){$('#entry-error').textContent='番茄长度请输入 1–240 的整数分钟。';return;}type='start';fields={...base,mode,minutes:mode==='pomodoro'?minutes:25};}if(await mutate(type,fields,'#entry-error')){$('#new-title').value='';newCategoryManual=false;updateCategory('new');if(type==='manual'){selectedDate=dateKey(fields.start);resetManualTimes();chooseView('day');say('已添加“'+title+'”，正在显示 '+fullDate(selectedDate)+'。');}else{$('#view-record').scrollTop=0;say('已开始“'+title+'”。');}}}
  function editFingerprint(){return JSON.stringify([...$('#edit-form').querySelectorAll('input,select')].map(el=>[el.id,el.type==='checkbox'?el.checked:el.value]));}
  function isEditDirty(){return editingBase&&editFingerprint()!==editingFingerprint;}
  function checkEditorConflict(){if(!editingBase)return;const current=records.find(r=>r.id===editingBase.id),stale=!current||current.revision!==editingBase.revision;$('#edit-conflict').hidden=!stale;$('#edit-reload').hidden=!stale||!current;$('#edit-conflict').textContent=!current?'这条记录已被删除。当前草稿已保留，可复制后关闭。':stale?'这条记录已更新（可能已到时结束）。当前草稿已保留，请重新读取后修改。':'';}
  function openEditor(id){const r=records.find(item=>item.id===id);if(!r){say('记录已不存在。',true,true);return;}if(inFlight)return;editingBase=clone(r);editCategoryManual=r.categoryManual;editRecognition=false;$('#edit-title').value=r.title;$('#edit-category').value=r.category;$('#edit-id').textContent=r.mode==='pomodoro'?'番茄钟':'时间记录';$('#editor-state').textContent=r.end===null?'进行中 · 修改这项不会影响其他任务':'已完成 · 可修正或删除';$('#edit-start-date').value=dateKey(r.start);$('#edit-end-date').value=dateKey(r.end===null?now():r.end);$('#edit-start-date').dataset.previous=dateKey(r.start);$('#edit-start').value=time(r.start);$('#edit-end').value=r.end===null?'':time(r.end);$('#edit-end-label').textContent=r.end===null?'结束（留空继续）':'结束时间';$('#edit-minutes').value=r.minutes;$('#edit-pomo-field').hidden=r.mode!=='pomodoro'||r.end!==null;$('#edit-stop').hidden=r.end!==null;$('#edit-delete').textContent=r.end===null?'停止并删除':'删除记录';$('#edit-date-fields').hidden=true;$('#edit-date-toggle').setAttribute('aria-expanded','false');$('#edit-error').textContent='';syncDateSummary('edit');updateCategory('edit');updateEditorPreview();checkEditorConflict();if(!$('#editor').open)$('#editor').showModal();editingFingerprint=editFingerprint();syncBusy();}
  async function closeEditor(){if(inFlight)return;if(isEditDirty()&&!await confirmAction('放弃这次尚未保存的修改？','放弃修改'))return;$('#editor').close();editingBase=null;}
  function updateEditorPreview(){const r=editingBase;if(!r)return;const start=sameFormTime('edit','start',r.start)?r.start:formTime('edit','start'),end=$('#edit-end').value?formTime('edit','end'):now();const overlaps=records.filter(item=>item.id!==r.id&&item.start<end&&recordEnd(item)>start);$('#edit-overlap').hidden=!overlaps.length;$('#edit-overlap').textContent=overlaps.length?'与 '+overlaps.length+' 项记录同时进行，仍分别保留。':'';const explicit=!!$('#edit-end').value;if(r.end!==null){$('#edit-save').textContent='保存修改';$('#edit-help').textContent='只改名称或分类会保留原始起止时刻。';}else if(r.mode==='pomodoro'){const deadline=start+Number($('#edit-minutes').value)*MINUTE,expired=Number.isFinite(deadline)&&deadline<=now();$('#edit-save').textContent=explicit||expired?'保存并结束':'保存 · 继续计时';$('#edit-help').textContent='新截止时间：'+(Number.isFinite(deadline)?fullDate(dateKey(deadline))+' '+time(deadline):'待填写')+'。'+(explicit?'保存将按填写的结束时间完成这一项。':expired?'该截止已过，保存将按新截止结束本轮。':'结束时间留空可继续计时。');}else{$('#edit-save').textContent=explicit?'保存并结束':'保存 · 继续计时';$('#edit-help').textContent=explicit?'保存将按填写的结束时间完成这一项。':'结束时间留空，保存信息并继续计时。';}}
  async function editSave(event,finish=false){event?.preventDefault();const r=editingBase;if(!r||inFlight)return;const current=records.find(item=>item.id===r.id);if(!current||current.revision!==r.revision){checkEditorConflict();return;}const start=sameFormTime('edit','start',r.start)?r.start:formTime('edit','start'),explicit=!!$('#edit-end').value;let end=r.end!==null&&sameFormTime('edit','end',r.end)?r.end:explicit?formTime('edit','end'):finish?now():null;let intent=r.end===null&&(finish||explicit)?'finish':'preserve';const minutes=Number($('#edit-minutes').value),deadline=start+minutes*MINUTE;if(r.end===null&&r.mode==='pomodoro'&&!explicit&&!finish&&deadline<=now()){intent='deadline';end=deadline;}let error='';if(!Number.isFinite(start)||start>now())error='开始时间必须有效且不能晚于当前时刻。';else if(end!==null)error=validRange(start,end);else if(r.end!==null)error='已完成记录必须保留结束时间。';if(!error&&r.mode==='pomodoro'&&(!Number.isInteger(minutes)||minutes<1||minutes>240))error='番茄长度请输入 1–240 的整数分钟。';if(error){$('#edit-error').textContent=error;return;}if(await mutate('edit',{id:r.id,expectedRevision:r.revision,title:$('#edit-title').value.trim()||'未命名事项',category:$('#edit-category').value,categoryManual:editCategoryManual,start,end,minutes,completionIntent:intent},'#edit-error')){$('#editor').close();editingBase=null;say('已保存修改。');}}
  async function deleteEditingRecord(){const r=editingBase;if(!r||inFlight)return;const active=r.end===null;if(!await confirmAction((active?'停止计时并删除':'删除')+'“'+r.title+'”？\n这项操作不会影响其他记录。',active?'停止并删除':'删除'))return;if(await mutate('delete',{id:r.id,expectedRevision:r.revision},'#edit-error')){$('#editor').close();editingBase=null;say('已删除“'+r.title+'”。');}}
  async function utility(action){$('#tools-menu').hidden=true;$('#tools-toggle').setAttribute('aria-expanded','false');if(inFlight)return;try{if(action==='load'){await load();return;}const [name,format]=action.split(':'),result=await native({action:name,...(format?{format}:{})});if(result?.cancelled)return;if(name==='import'){receiveSnapshot(result);say('已导入备份。');}else if(name==='export')say('已导出文件。');else if(name==='notifications'){const status=result?.status;const labels={authorized:'已允许到时通知。',denied:'通知未开启，可在系统设置中允许。',provisional:'已允许安静通知。',notDetermined:'尚未允许通知。'};say(labels[status]||'通知设置：'+(status||'已更新'));}}catch(error){say(message(error),true,true);}}
  // Keep one canonical HH:mm input; select segments without relying on WebKit's native time widget.
  for(const input of document.querySelectorAll('.clock-input')){
    let segment='',digits='';
    const reset=()=>{segment='';digits='';};
    const selectPart=part=>{const split=input.value.indexOf(':');if(part==='minute')input.setSelectionRange(split+1,input.value.length);else input.setSelectionRange(0,split<0?input.value.length:split);};
    const normalize=()=>{const m=input.value.trim().match(/^(\d{1,2})(?::(\d{1,2}))?$/);if(m)input.value=pad(Number(m[1]))+':'+pad(Number(m[2]||0));};
    input.addEventListener('pointerdown',reset);
    input.addEventListener('focus',reset);
    input.addEventListener('blur',()=>{normalize();reset();input.dispatchEvent(new Event('input',{bubbles:true}));});
    input.addEventListener('paste',()=>{reset();});
    input.addEventListener('keydown',event=>{
      if(event.ctrlKey||event.metaKey||event.altKey)return;
      const split=input.value.indexOf(':'),part=split>=0&&input.selectionStart>split?'minute':'hour';
      if(event.key==='ArrowRight'||event.key===':'||(event.key==='Tab'&&!event.shiftKey&&part==='hour'&&input.value)){
        event.preventDefault();normalize();reset();selectPart('minute');return;
      }
      if(event.key==='ArrowLeft'){event.preventDefault();normalize();reset();selectPart('hour');return;}
      if(!/^\d$/.test(event.key)){reset();return;}
      event.preventDefault();if(segment!==part||digits.length===2){segment=part;digits='';}digits+=event.key;
      const old=input.value.match(/^(\d{1,2}):(\d{1,2})$/),hour=old?old[1]:'',minute=old?old[2]:'00';
      input.value=part==='hour'?pad(Number(digits))+':'+minute:(hour||'00')+':'+pad(Number(digits));
      input.dispatchEvent(new Event('input',{bubbles:true}));
      if(part==='hour'&&digits.length===2){reset();selectPart('minute');}else selectPart(part);
    });
  }
  // Only the native store supplies canonical facts. Pushed revisions never replace form inputs.
  window.timeNote=Object.freeze({receiveSnapshot:snapshot=>{try{return receiveSnapshot(snapshot);}catch(error){say(message(error),true,true);return false;}},openRecord:id=>{chooseView('record');if(typeof id==='string')openEditor(id);else $('#new-title').focus();}});
  for(const [id,cat]of Object.entries(cats))for(const select of [$('#new-category'),$('#edit-category')]){const option=element('option','',cat.name);option.value=id;select.append(option);}
  $('#new-category').value='other';resetManualTimes();updateCategory('new');
  for(const id of ['manage-categories','new-manage-categories','edit-manage-categories'])$('#'+id).addEventListener('click',openCategoryManager);
  $('#category-close').addEventListener('click',()=>{if(!inFlight)$('#category-manager').close();});
  $('#category-manager').addEventListener('cancel',event=>{if(inFlight)event.preventDefault();});
  $('#category-reset').addEventListener('click',resetCategoryForm);
  $('#category-form').addEventListener('submit',async event=>{event.preventDefault();const name=$('#category-name').value.trim();if(!name){$('#category-error').textContent='请填写标签名称。';return;}const fields=categoryEditing?{id:categoryEditing.id,expectedRevision:categoryEditing.revision,name,color:categoryColor}:{name,color:categoryColor};if(await mutate(categoryEditing?'categoryEdit':'categoryAdd',fields,'#category-error')){resetCategoryForm();$('#category-name').focus();}});

  for(const button of document.querySelectorAll('[data-view]'))if(button.matches('button'))button.addEventListener('click',()=>chooseView(button.dataset.view));
  $('.tabs').addEventListener('keydown',event=>{if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;event.preventDefault();const order=['day','week','record'],index=event.key==='Home'?0:event.key==='End'?2:(order.indexOf(view)+(event.key==='ArrowRight'?1:2))%3;chooseView(order[index]);$('#tab-'+order[index]).focus();});
  $('#prev-date').addEventListener('click',()=>{selectedDate=addDays(selectedDate,view==='week'?-7:-1);renderData();});$('#next-date').addEventListener('click',()=>{selectedDate=addDays(selectedDate,view==='week'?7:1);renderData();});
  $('#activity-line').addEventListener('click',()=>{chooseView('record');$('#view-record').scrollTop=0;});
  for(const button of document.querySelectorAll('[data-entry-mode]'))button.addEventListener('click',()=>{if(!inFlight)updateEntryMode(button.dataset.entryMode);});
  $('#new-title').addEventListener('input',()=>updateCategory('new'));$('#new-category').addEventListener('change',()=>{newCategoryManual=true;updateCategory('new');});$('#new-category-reset').addEventListener('click',()=>{newCategoryManual=false;updateCategory('new');});$('#new-timer-mode').addEventListener('change',updateTimerMode);$('#entry-form').addEventListener('submit',startOrAdd);
  for(const prefix of ['new','edit']){
    $('#'+prefix+'-date-toggle').addEventListener('click',()=>{const fields=$('#'+prefix+'-date-fields');fields.hidden=!fields.hidden;$('#'+prefix+'-date-toggle').setAttribute('aria-expanded',String(!fields.hidden));});
    for(const edge of ['start','end'])$('#'+prefix+'-'+edge+'-date').addEventListener('change',()=>{if(prefix==='new')manualDateTouched=true;const start=$('#'+prefix+'-start-date');if(edge==='start'&&$('#'+prefix+'-end-date').value===start.dataset.previous)$('#'+prefix+'-end-date').value=start.value;start.dataset.previous=start.value;syncDateSummary(prefix);if(prefix==='edit')updateEditorPreview();});
    $('#'+prefix+'-next-day').addEventListener('change',()=>{const start=$('#'+prefix+'-start-date').value;if(!Number.isFinite(dayStart(start))){$('#'+prefix+'-next-day').checked=false;$('#'+(prefix==='new'?'entry':'edit')+'-error').textContent='请先填写有效的开始日期。';return;}if(prefix==='new')manualDateTouched=true;$('#'+prefix+'-end-date').value=$('#'+prefix+'-next-day').checked?addDays(start,1):start;syncDateSummary(prefix);if(prefix==='edit')updateEditorPreview();});
  }
  $('#todo-form').addEventListener('submit',async event=>{event.preventDefault();const title=$('#todo-input').value.trim(),day=selectedDate;if(!title)return;if(await mutate('todoAdd',{day,title}))$('#todo-input').value='';});
  $('#edit-category').addEventListener('change',()=>{editCategoryManual=true;updateCategory('edit');});$('#edit-category-reset').addEventListener('click',()=>{editCategoryManual=false;editRecognition=true;$('#edit-category').value=guessCategory($('#edit-title').value);updateCategory('edit');});$('#edit-title').addEventListener('input',()=>updateCategory('edit'));for(const id of ['edit-start','edit-end','edit-minutes'])$('#'+id).addEventListener('input',updateEditorPreview);
  $('#edit-form').addEventListener('submit',editSave);$('#edit-stop').addEventListener('click',()=>editSave(null,true));$('#edit-delete').addEventListener('click',deleteEditingRecord);$('#editor-close').addEventListener('click',closeEditor);$('#edit-cancel').addEventListener('click',closeEditor);$('#editor').addEventListener('cancel',event=>{event.preventDefault();closeEditor();});$('#edit-reload').addEventListener('click',async()=>{const id=editingBase?.id;if(id&&await confirmAction('放弃当前草稿，重新读取这条记录？','重新读取'))openEditor(id);});
  $('#overlap-close').addEventListener('click',()=>$('#overlap-picker').close());$('#confirm-ok').addEventListener('click',()=>settleConfirm(true));$('#confirm-cancel').addEventListener('click',()=>settleConfirm(false));$('#confirm-dialog').addEventListener('cancel',event=>{event.preventDefault();settleConfirm(false);});
  $('#tools-toggle').addEventListener('click',()=>{const menu=$('#tools-menu');menu.hidden=!menu.hidden;$('#tools-toggle').setAttribute('aria-expanded',String(!menu.hidden));});for(const button of document.querySelectorAll('[data-utility]'))button.addEventListener('click',()=>utility(button.dataset.utility));document.addEventListener('pointerdown',event=>{if(!event.target.closest('.tools')){$('#tools-menu').hidden=true;$('#tools-toggle').setAttribute('aria-expanded','false');}});$('#time-peek').addEventListener('pointerenter',()=>{if(peekTimer)clearTimeout(peekTimer);});$('#time-peek').addEventListener('pointerleave',hidePeek);
  setInterval(()=>{const today=dateKey(now()),minute=Math.floor(now()/MINUTE);if(today!==lastToday){if(selectedDate===lastToday)selectedDate=today;lastToday=today;renderDate();}renderClocks();if(editingBase)updateEditorPreview();if(minute!==lastMinute){lastMinute=minute;if(view==='day')renderDay();if(view==='week')renderWeek();}},1000);
  renderData();syncBusy();load();
})();
