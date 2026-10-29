/* Native bar follows the existing web route and never changes stored records. */
(() => {
  const bridge=window.KcalNative,nav=document.getElementById('primaryNav');
  let enabled=false,inFlight=false,confirmed='',desired='';
  function disable(){
    enabled=false;
    document.documentElement.classList.remove('native-navigation');
    nav.removeAttribute('aria-hidden');
    // Hide an already-applied native state even if its earlier acknowledgement was lost.
    bridge.call('nav.disable').catch(()=>{});
  }
  function current(){
    return {section:document.getElementById('navHealth').getAttribute('aria-current')==='page'?'health':'diet',
      visible:!document.hidden && !document.querySelector('.modal.on')};
  }
  async function publish(){
    if(!enabled)return;
    desired=JSON.stringify(current());
    if(inFlight || desired===confirmed)return;
    inFlight=true;
    const sent=desired;
    try{
      const reply=await bridge.call('nav.state',JSON.parse(sent));
      if(!enabled)return;
      if(reply?.accepted!==true)throw new Error('Native navigation not accepted');
      confirmed=sent;
      // Retain working HTML navigation until native hosting acknowledges the state.
      document.documentElement.classList.add('native-navigation');
      nav.setAttribute('aria-hidden','true');
    }catch{
      disable();
    }finally{
      inFlight=false;
      if(enabled && desired!==confirmed)publish();
    }
  }
  window.KcalNativeNavigation={
    select(section){
      if(!enabled || !current().visible || !['diet','health'].includes(section))return false;
      document.getElementById(section==='diet'?'navDiet':'navHealth').click();
      publish();
      return true;
    },
    setEnabled(value){
      if(value!==false)return;
      disable();
    },
    setClearance(points){
      if(Number.isFinite(points) && points>=0 && points<=600)
        document.documentElement.style.setProperty('--native-tab-clearance',points+'px');
    }
  };
  new MutationObserver(publish).observe(document.body,{subtree:true,attributes:true,attributeFilter:['aria-current','class','hidden']});
  for(const name of ['hashchange','popstate','pageshow','visibilitychange'])window.addEventListener(name,publish);
  bridge.ready.then(info=>{enabled=info.nativeNavigation===true;publish();}).catch(()=>{});
})();
