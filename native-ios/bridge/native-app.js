/* Runs after the unmodified application logic in the generated iOS bundle. */
(() => {
  const bridge = window.KcalNative;
  const status = $('nativeSyncStatus'), button = $('btnNativeSync');
  const auto = $('nativeAutoSync'), source = $('nativeSleepSource');
  let busy = false, lastAttempt = 0, preferences = {autoSync:false,sleepSource:''};
  $('nativeFrom').value = shiftDay(todayKey(),-6); $('nativeThrough').value = todayKey();
  $('verLabel').textContent = 'iOS 1.0.0 · 网页 ' + APP_VERSION;
  $('btnUpdate').textContent = '安装与续签说明';
  $('btnUpdate').addEventListener('click',()=>bridge.call('external.open',{url:'https://github.com/StarKpEz/Kcal_Analysis'}).catch(error=>toast(error.message)));
  $('btnReloadData').addEventListener('click',()=>location.reload());
  function setBusy(value){busy=value;button.disabled=value;auto.disabled=value;source.disabled=value;button.textContent=value?'正在读取…':'连接并同步 Apple 健康';if(value)$('nativeSyncDetails').hidden=true;}
  function report(message,notes=[]){status.textContent=message;$('nativeSyncNotes').textContent=notes.join('\n');$('nativeSyncDetails').hidden=!notes.length;}
  function showSources(result){
    const choices=Array.isArray(result.sleepSources)?result.sleepSources:[];
    source.replaceChildren(new Option('选择睡眠来源', ''));
    for(const choice of choices) if(typeof choice.id==='string' && typeof choice.name==='string') source.add(new Option(choice.name,choice.id));
    source.value=preferences.sleepSource || '';source.hidden=choices.length<2 && !preferences.sleepSource;
    $('nativeSleepLabel').hidden=source.hidden;
  }
  async function sync(automatic = false){
    if(busy || storageReadError || storageStale) return;
    if(automatic && (Date.now()-lastAttempt<60000 || document.hidden || document.querySelector('.modal.on') || $('dlg').classList.contains('on'))) return;
    const through=automatic?todayKey():$('nativeThrough').value,from=automatic?shiftDay(through,-6):$('nativeFrom').value;
    if(!isDayKey(from)||!isDayKey(through)||from>through||through>todayKey()){status.textContent='请选择有效的日期范围，结束日期不能在未来。';return;}
    lastAttempt=Date.now();setBusy(true);
    try{
      if(!automatic) await bridge.call('health.authorize');
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
      if(desired) await bridge.call('health.authorize');
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
  bridge.call('preferences.load').then(value=>{
    preferences=value;auto.checked=!!value.autoSync;
    if(value.autoSync)sync(true);
  }).catch(error=>{status.textContent='自动刷新设置读取失败：'+error.message;});
})();
