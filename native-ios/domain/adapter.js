// Hand-written command boundary. All calculation/backup/health algorithms above are extracted from the PWA.
const domainDefaults = () => ({app:'kcal',version:7,entries:{},settings:{...DEFAULT_SETTINGS},body:{...DEFAULT_BODY},weight:{},weightMeta:{},burn:{},training:{},sleep:{},completion:{},meta:{lastBackup:''}});
function domainLoad(value) {
  if (value == null) return domainDefaults();
  if (!isObject(value) || value.app !== 'kcal' || ![5,6,7].includes(value.version)) throw Error('本地快照格式无效，请先导出原始恢复文件');
  const fields = validateBackup(value);
  return {...domainDefaults(),...fields,settings:{...DEFAULT_SETTINGS,...fields.settings},body:{...DEFAULT_BODY,...fields.body}};
}
function domainDate(value) { if (!isDayKey(value)) throw Error('日期无效'); return value; }
function domainMeal(value, legacy=false) { if (!MEAL_KEYS.includes(value) && !(legacy && value===LEGACY)) throw Error('餐次无效'); return value; }
function domainText(value) { if (typeof value !== 'string') throw Error('请输入文本'); return value.replace(/^\uFEFF/,'').trim(); }
function domainRestore(text) {
  text=domainText(text);
  let data;
  try {data=JSON.parse(text);} catch(error) {
    if (/^[\[{]/.test(text)) throw Error('JSON 文件不完整或格式错误');
    const entries=normalizeStore(parseChatDoc(text));
    if (!countParsed(entries).total) throw Error('没解析出带日期的饮食记录');
    return {fields:{entries},version:null,fromDocument:true};
  }
  return {fields:validateBackup(data),version:data.version??null,fromDocument:false};
}
function domainHealth(payload) {
  if (payload.from != null || payload.through != null) {
    domainDate(payload.from); domainDate(payload.through);
    if (payload.from > payload.through) throw Error('健康日期范围无效');
  }
  let documents = payload.documents;
  const notes = [];
  if (payload.result != null || payload.nativeResult != null) {
    const result=payload.nativeResult??payload.result;
    if (!isObject(result) || !Array.isArray(result.notes) || result.notes.some(n=>typeof n!=='string')) throw Error('健康读取结果无效');
    notes.push(...result.notes);
    if (payload.from && result.daily?.days?.some(day=>day.date<payload.from || day.date>payload.through)) throw Error('健康返回日期超出所选范围');
    if (payload.from && result.sleepSamples && (result.sleepSamples.from!==payload.from || result.sleepSamples.through!==payload.through)) throw Error('睡眠返回范围与所选日期不一致');
    documents=[result.daily,result.sleepSamples].filter(v=>v!=null);
  }
  if (documents == null) documents=[domainText(payload.text)];
  if (!Array.isArray(documents) || documents.length>10) throw Error('健康批次格式无效');
  const fields={burn:{},training:{},sleep:{},weight:{},weightMeta:{}};
  for (const documentValue of documents) {
    const parsed=parseHealthJSON(typeof documentValue==='string'?documentValue:JSON.stringify(documentValue));
    for (const key of Object.keys(fields)) for (const [date,value] of Object.entries(parsed[key]||{})) {
      if (payload.from && (date<payload.from || date>payload.through)) throw Error('健康返回日期超出所选范围');
      if (Object.hasOwn(fields[key],date)) throw Error('同一天健康数据重复，请重新读取');
      fields[key][date]=cloneData(value);
    }
    if (parsed.notes) notes.push(...parsed.notes);
  }
  fields.notes=[...new Set(notes)];
  return {fields,...healthImportPlan(fields)};
}
function domainSameValue(a,b) {
  if(a===b)return true;
  if(a==null||b==null||typeof a!=='object'||typeof b!=='object')return false;
  if(Array.isArray(a)!==Array.isArray(b))return false;
  const keys=Object.keys(a);
  return keys.length===Object.keys(b).length&&keys.every(key=>Object.hasOwn(b,key)&&domainSameValue(a[key],b[key]));
}
function domainItem(payload, entries) {
  const date=domainDate(payload.date),meal=domainMeal(payload.meal??payload.fromMeal,true),list=entries[date]?.[meal];
  if (!Array.isArray(list)||!Number.isInteger(payload.index)||payload.index<0||payload.index>=list.length) throw Error('饮食条目已变更，请重新打开');
  if(Object.hasOwn(payload,'expectedItem')&&!domainSameValue(list[payload.index],payload.expectedItem))throw Error('饮食条目已被其他操作修改，请返回列表后重新打开');
  return {date,meal,list,item:list[payload.index]};
}
function domainSummary(date) {
  domainDate(date);
  const meals=MEAL_KEYS.concat([LEGACY]).map(key=>({key,name:key===LEGACY?'未分餐':mealName(key),items:cloneData(store[date]?.[key]||[]),totals:sum(store[date]?.[key]||[])}));
  const totals=sum(meals.flatMap(m=>m.items));
  return {date,totals,meals,energy:energyBalance(date,body,weight,burnByDay),training:trainingByDay[date]??null,sleep:sleepByDay[date]??null,weight:weight[date]??null,weightMeta:weightMeta[date]??null,completion:completion[date]??{food:false,energy:false}};
}
function domainQuery(operation,payload) {
  switch(operation) {
    case 'initialize': return {snapshot:dataSnapshot()};
    case 'summary': return domainSummary(payload.date??todayKey());
    case 'range': {
      const from=domainDate(payload.from),through=domainDate(payload.through);
      if(from>through)throw Error('日期范围无效');
      const days=[];let cursor=from;
      while(cursor<=through) {if(days.length>=3660)throw Error('统计范围超过十年');days.push(domainSummary(cursor));cursor=shiftDay(cursor,1);}
      return {days,totals:days.reduce((s,d)=>({kcal:s.kcal+d.totals.kcal,p:s.p+d.totals.p,f:s.f+d.totals.f,c:s.c+d.totals.c}),{kcal:0,p:0,f:0,c:0})};
    }
    case 'parseFood': {
      const items=parseText(domainText(payload.text));
      validateBackup({entries:{[todayKey()]:{lunch:items}}});
      return {items,totals:sum(items)};
    }
    case 'parseChat': {
      const entries=normalizeStore(parseChatDoc(domainText(payload.text))),stat=countParsed(entries);
      if(!stat.total)throw Error('没解析出带日期的饮食记录');
      validateBackup({entries});return {entries,days:stat.dates.length,items:stat.total,dates:stat.dates};
    }
    case 'foodPrompt': {
      const meal=mealName(domainMeal(payload.meal??'lunch')),description=String(payload.description??'').trim();
      return {text:`【餐次】${meal}\n${description?`【我的描述】${description}\n`:''}估算这一餐的热量和三大营养素；如有照片请结合照片。考虑中式烹饪用油。逐项列出食物、重量、热量、蛋白质、脂肪和碳水，最后给出合计。只用一行一项，不要输出表格或额外解释：\n米饭 | 200g | 232kcal | 蛋白质5g | 脂肪0.6g | 碳水51g\n红烧肉 | 80g | 320kcal | 蛋白质10g | 脂肪30g | 碳水3g\n合计 | - | 552kcal | 蛋白质15g | 脂肪30.6g | 碳水54g`};
    }
    case 'previewRestore': {
      const parsed=domainRestore(payload.text),fields=parsed.fields,stat=countParsed(fields.entries||{});
      const dates=[...new Set(['entries','weight','burn','training','sleep'].flatMap(k=>Object.keys(fields[k]||{})))].sort();
      const counts=Object.fromEntries(['weight','burn','training','sleep'].map(k=>[k,Object.keys(fields[k]||{}).length]));
      const details=[`${stat.dates.length} 天 · ${stat.total} 条饮食记录`,`${counts.weight} 天体重 · ${counts.burn} 天能量 · ${counts.training} 天训练 · ${counts.sleep} 天睡眠`];
      if(dates.length)details.push('日期：'+dates[0]+' 至 '+dates.at(-1));
      if(fields.settings)details.push('包含目标设置');if(fields.body)details.push('包含身体档案');
      details.push('覆盖会替换备份包含的整类数据；未提供的类别保留。','合并时，同一天的体重、能量、训练和睡眠以备份为准。');
      return {...parsed,days:stat.dates.length,items:stat.total,dates,counts,details,summary:`${stat.dates.length} 天 · ${stat.total} 条饮食记录`};
    }
    case 'previewHealth': {const plan=domainHealth(payload);return {updates:plan.updates,skipped:plan.skipped,conflicts:plan.conflicts,details:plan.details,summary:plan.summary,notes:plan.fields.notes};}
    case 'energy': {
      const date=domainDate(payload.date??todayKey()),energy=energyBalance(date,body,weight,burnByDay);
      return {...energy,trend:reverseTDEE(store,weight,{asOf:date}),target:suggestTarget(calcTDEE(energy.bmr,body.activity),body.sex),activityLevels:ACTIVITY_LEVELS};
    }
    case 'reverseTDEE': return reverseTDEE(store,weight,{asOf:domainDate(payload.asOf??payload.date??todayKey())});
    case 'weightWindow': return weightWindow(weight,payload.mode??'all',domainDate(payload.anchor??todayKey()),domainDate(payload.asOf??todayKey()));
    case 'exportBackup': return {text:JSON.stringify({...dataSnapshot(),exportedAt:new Date().toISOString()},null,2)};
    default: throw Error('不支持的读取操作：'+operation);
  }
}
function domainMutate(operation,payload) {
  const before=cloneData(dataSnapshot());let next=cloneData(before),result={};
  switch(operation) {
    case 'patch': {
      const fields=validateBackup(payload.patch);
      next={...next,...fields};
      if(fields.settings)next.settings={...before.settings,...fields.settings};
      if(fields.body)next.body={...before.body,...fields.body};
      break;
    }
    case 'addFood': {
      const date=domainDate(payload.date),meal=domainMeal(payload.meal),items=cloneData(payload.items);
      if(!Array.isArray(items)||!items.length)throw Error('没有可保存的饮食条目');
      validateBackup({entries:{[date]:{[meal]:items}}});
      next.entries[date]??={};next.entries[date][meal]??=[];next.entries[date][meal].push(...items);result={added:items.length};break;
    }
    case 'deleteFood': {const found=domainItem(payload,next.entries);found.list.splice(payload.index,1);break;}
    case 'editFood': {const found=domainItem(payload,next.entries);found.list[payload.index]={...found.item,...payload.item};break;}
    case 'scaleFood': {
      const found=domainItem(payload,next.entries),grams=payload.grams;
      if(typeof grams!=='number'||!Number.isFinite(grams)||grams<0)throw Error('重量无效');
      const old=+found.item.grams||0;
      if(old>0&&grams>0)for(const key of ['kcal','protein','fat','carbs'])found.item[key]=(+found.item[key]||0)*grams/old;
      found.item.grams=grams;break;
    }
    case 'moveFood': {
      const found=domainItem(payload,next.entries),target=domainMeal(payload.toMeal);
      if(found.meal!==target){next.entries[found.date][target]??=[];next.entries[found.date][target].push(found.list.splice(payload.index,1)[0]);}break;
    }
    case 'importChat':
    case 'restore': {
      if(!['merge','replace'].includes(payload.mode))throw Error('请选择合并或覆盖恢复');
      const parsed=domainRestore(payload.text);
      if(payload.recovering && (payload.mode!=='replace'||![5,6,7].includes(parsed.version)))throw Error('本地读取异常，仅能覆盖恢复有效的 v5/v6/v7 完整备份');
      next=importedSnapshot(parsed.fields,payload.mode);result={mode:payload.mode};break;
    }
    case 'importHealth': {
      const plan=domainHealth(payload);
      if(payload.automatic && plan.conflicts)throw Error('健康数据包含手动记录，请确认覆盖内容');
      next={...next,...plan.patch};result={updates:plan.updates,skipped:plan.skipped,conflicts:plan.conflicts,details:plan.details,notes:plan.fields.notes};break;
    }
    case 'saveWeight': {
      const date=domainDate(payload.date),value=payload.value;
      if(typeof value!=='number'||!Number.isFinite(value)||value<=0||value>400)throw Error('体重须大于 0 且不超过 400 kg');
      next.weight[date]=value;next.weightMeta[date]={source:'manual',updatedAt:new Date().toISOString()};break;
    }
    case 'saveEnergy': {
      const date=domainDate(payload.date);
      if(!validEnergy(payload.active)||!validEnergy(payload.basal))throw Error('请同时填写有效的活动与静息能量，允许明确的 0');
      next.burn[date]={active:payload.active,basal:payload.basal,updatedAt:new Date().toISOString()};break;
    }
    case 'saveTraining': {
      const date=domainDate(payload.date),old=next.training[date],input=payload.input;
      if(!isObject(input))throw Error('训练输入无效');
      const editingId=payload.id||'',sessions=cloneData(old?.sessions||[]),index=sessions.findIndex(s=>s.id===editingId);
      if(editingId&&index<0)throw Error('编辑的训练已变更，请重新打开');
      const item={id:editingId||'manual-'+Date.now()+'-'+Math.random().toString(36).slice(2),type:input.type,durationMinutes:input.durationMinutes};
      for(const key of ['distanceKm','energyKcal'])if(input[key]!=null)item[key]=input[key];
      if(index>=0){if(sessions[index].startAt)item.startAt=sessions[index].startAt;sessions[index]=item;}else sessions.push(item);
      next.training[date]=normalizeTrainingDay({sessions,source:old?.source==='health-json'||old?.source==='mixed'?'mixed':'manual',updatedAt:new Date().toISOString()},date);break;
    }
    case 'deleteTraining': {
      const date=domainDate(payload.date),old=next.training[date];
      if(!old?.sessions.some(s=>s.id===payload.id))throw Error('训练已变更，请重新打开');
      next.training[date]={...old,sessions:old.sessions.filter(s=>s.id!==payload.id),source:old.source==='manual'?'manual':'mixed',updatedAt:new Date().toISOString()};break;
    }
    case 'saveSleep': {const date=domainDate(payload.date);next.sleep[date]=normalizeSleepDay({...payload.input,source:'manual',updatedAt:new Date().toISOString()},date);break;}
    case 'markCompletion': {const date=domainDate(payload.date);next.completion[date]={...{food:false,energy:false},...next.completion[date],...payload.value};break;}
    case 'clearDiet':
    case 'clearCategory': {
      const date=domainDate(payload.date),category=operation==='clearDiet'?'entries':payload.category;
      if(!['entries','burn','weight','training','sleep'].includes(category))throw Error('记录类别无效');
      delete next[category][date];if(category==='weight')delete next.weightMeta[date];break;
    }
    default:throw Error('不支持的保存操作：'+operation);
  }
  // Ordinary mutations invalidate only the changed category's old completion flag.
  // Restore preserves the existing importedSnapshot matching rules.
  if(!['restore','importChat'].includes(operation))for(const date of new Set([...Object.keys(before.entries),...Object.keys(next.entries),...Object.keys(before.burn),...Object.keys(next.burn)])) {
    if(JSON.stringify(before.entries[date])!==JSON.stringify(next.entries[date]))next.completion[date]={...{food:false,energy:false},...next.completion[date],food:false};
    if(JSON.stringify(before.burn[date])!==JSON.stringify(next.burn[date]))next.completion[date]={...{food:false,energy:false},...next.completion[date],energy:false};
  }
  next={...domainDefaults(),...validateBackup(next)};
  return {...result,snapshot:next,changed:JSON.stringify(before)!==JSON.stringify(next)};
}
scope.NativeDomainEngine={execute(raw) {
  try {
    const request=JSON.parse(raw);
    if(!isObject(request)||!isObject(request.payload||{}))throw Error('操作参数无效');
    applySnapshot(domainLoad(request.snapshot));
    const value=request.mutation?domainMutate(request.operation,request.payload||{}):domainQuery(request.operation,request.payload||{});
    return JSON.stringify({ok:true,value});
  }catch(error){return JSON.stringify({ok:false,error:String(error.message||error)});}
}};
