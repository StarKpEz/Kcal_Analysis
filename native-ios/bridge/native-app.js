/* Runs after the unmodified application logic in the generated iOS bundle. */
(() => {
  const bridge = window.KcalNative;
  const status = $('nativeSyncStatus'), button = $('btnNativeSync');
  const auto = $('nativeAutoSync'), source = $('nativeSleepSource');
  let busy = false, lastAttempt = 0, preferences = {autoSync:false,sleepSource:''};
  $('nativeFrom').value = shiftDay(todayKey(),-6); $('nativeThrough').value = todayKey();
  $('verLabel').textContent = 'iOS · 网页 ' + APP_VERSION;
  $('btnUpdate').textContent = '安装与续签说明';
  $('btnUpdate').addEventListener('click',()=>bridge.call('external.open',{url:'https://github.com/StarKpEz/Kcal_Analysis'}).catch(error=>toast(error.message)));
  $('btnReloadData').addEventListener('click',()=>location.reload());
  function setBusy(value){busy=value;button.disabled=value;auto.disabled=value;source.disabled=value;button.textContent=value?'正在同步…':'连接并同步 Apple 健康';if(value)$('nativeSyncDetails').hidden=true;}
  function report(message,notes=[]){status.textContent=message;$('nativeSyncNotes').textContent=notes.join('\n');$('nativeSyncDetails').hidden=!notes.length;}
  function showSources(result){
    const choices=Array.isArray(result.sleepSources)?result.sleepSources:[];
    source.replaceChildren(new Option('选择睡眠来源', ''));
    for(const choice of choices) if(typeof choice.id==='string' && typeof choice.name==='string') source.add(new Option(choice.name,choice.id));
    source.value=preferences.sleepSource || '';source.hidden=choices.length<2 && !preferences.sleepSource;
    $('nativeSleepLabel').hidden=source.hidden;
  }
  async function sync(automatic = false){
    if(busy) return;
    if(storageReadError){report('本地记录读取异常，已暂停健康同步。请先到设置导出恢复文件并检查存储提示；已有记录不会被覆盖。');return;}
    if(storageStale){report('本地记录已被其他操作更新，请重新打开页面后再同步；已有记录已保留。');return;}
    if(automatic && (Date.now()-lastAttempt<60000 || document.hidden || document.querySelector('.modal.on') || $('dlg').classList.contains('on'))) return;
    const through=automatic?todayKey():$('nativeThrough').value,from=automatic?shiftDay(through,-6):$('nativeFrom').value;
    if(!isDayKey(from)||!isDayKey(through)||from>through||through>todayKey()){status.textContent='请选择有效的日期范围，结束日期不能在未来。';return;}
    lastAttempt=Date.now();setBusy(true);
    try{
      report('正在检查原生连接…');
      const info=await bridge.ready;
      if(!info.healthAvailable)throw new Error('此设备无法使用 Apple 健康，请检查设备与安装包的 HealthKit 配置');
      if(!automatic){report('正在请求 Apple 健康授权… 请在系统面板中选择允许读取的项目。');await bridge.call('health.authorize');}
      report('正在读取 Apple 健康…');
      const result=await bridge.call('health.sync',{from,through,sleepSource:preferences.sleepSource || null});
      showSources(result);
      const merged=mergeNativeHealth(result,parseHealthJSON,{from,through});
      if(!merged.fields){report('没有可更新的健康记录，已有数据已保留。',merged.notes);return;}
      const plan=healthImportPlan(merged.fields);
      if(!plan.updates){report('已有相同或更新的记录，本次未写入。',merged.notes);return;}
      if(automatic && plan.conflicts){status.textContent='读取到健康数据，其中包含手动记录。请点同步检查覆盖内容；本次自动刷新未写入。';return;}
      if(!automatic){
        const accepted=await askChoice({title:'更新 Apple 健康记录？',message:plan.details.join('\n')+'\n未提供的日期和类别保留。训练热量不再加入消耗。',buttons:[{label:'确认更新',value:true,strong:true},{label:'取消',value:false}]});
        if(!accepted){status.textContent='已取消，没有修改记录。';return;}
      }
      // Re-plan after the confirmation and save all categories with one synchronous native write.
      const latest=healthImportPlan(merged.fields);
      if(automatic && latest.conflicts) return;
      if(!latest.updates){status.textContent='已有相同或更新的记录，本次未写入。';return;}
      if(!commitData(latest.patch)){status.textContent='未能保存，原数据已保留。请核对存储提示。';return;}
      energyEditDate='';wellnessEditDate='';weightEditDate='';render();refreshRisk();
      report('已在本机保存 '+latest.updates+' 项日记录 · '+new Date().toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit'}),merged.notes);
    }catch(error){status.textContent='未更新：'+error.message+'\n已有记录已保留；没有可读样本不能直接判断为未授权。';}
    finally{setBusy(false);}
  }
  button.addEventListener('click',()=>sync(false));
  auto.addEventListener('change',async()=>{
    const desired=auto.checked;
    try{
      if(desired){await bridge.ready;await bridge.call('health.authorize');}
      preferences=await bridge.call('preferences.save',{autoSync:desired,sleepSource:preferences.sleepSource || ''});
      auto.checked=!!preferences.autoSync;
      if(desired) await sync(true);
    }catch(error){auto.checked=!!preferences.autoSync;status.textContent=error.message;}
  });
  source.addEventListener('change',async()=>{
    try{preferences=await bridge.call('preferences.save',{autoSync:!!preferences.autoSync,sleepSource:source.value});status.textContent='睡眠来源已选择，点同步读取。';}
    catch(error){status.textContent=error.message;source.value=preferences.sleepSource || '';}
  });
  bridge.onResume=()=>{if(preferences.autoSync)sync(true);};
  bridge.ready.then(info=>{
    $('verLabel').textContent='iOS '+info.appVersion+' ('+info.buildNumber+') · 网页 '+APP_VERSION;
    if(!busy && !storageReadError && !storageStale)report(info.healthAvailable?'原生连接已就绪。点击上方按钮授权并读取；无可读样本时保留已有记录。':'此设备无法使用 Apple 健康，请检查设备与安装包的 HealthKit 配置。');
    return bridge.call('preferences.load');
  }).then(value=>{
    preferences=value;auto.checked=!!value.autoSync;
    if(value.autoSync)sync(true);
  }).catch(error=>{if(!busy)report('原生连接或设置读取失败：'+error.message);});
})();
