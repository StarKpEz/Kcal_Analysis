// Glass navigation feedback. Existing links and routing remain authoritative.
(() => {
  const nav = document.getElementById('primaryNav');
  const inner = nav.querySelector('.tabbar-inner');
  const lens = document.createElement('span');
  lens.id = 'tabGlassLens'; lens.className = 'tab-glass-lens';
  lens.setAttribute('aria-hidden','true'); lens.hidden = true;
  inner.prepend(lens);
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  let frame = 0, current = '', lensMotion = null, iconMotion = null, initialized = false;
  const enabled = () => true;
  function position(animate = false){
    cancelAnimationFrame(frame); frame = 0;
    const active = inner.querySelector('a[aria-current="page"]');
    const shown = enabled() && !!active;
    lens.hidden = !shown;
    if (!shown) {
      lensMotion?.cancel(); iconMotion?.cancel(); lens.dataset.moving = 'false';
      initialized = false; current = ''; return;
    }
    const bounds = active.getBoundingClientRect(), parentBounds = inner.getBoundingClientRect();
    const target = bounds.left - parentBounds.left + 4, width = bounds.width - 8;
    const previous = lensMotion ? new DOMMatrixReadOnly(getComputedStyle(lens).transform).m41 : parseFloat(lens.style.getPropertyValue('--lens-x')) || target;
    const changed = current !== active.id;
    lensMotion?.cancel(); iconMotion?.cancel();
    lens.style.setProperty('--lens-x',target+'px'); lens.style.setProperty('--lens-width',width+'px');
    lens.dataset.selected = active.id; lens.dataset.moving = 'false';
    if (initialized && changed && animate && !reduced.matches && typeof lens.animate === 'function') {
      const direction = Math.sign(target - previous);
      lens.dataset.moving = 'true';
      lensMotion = lens.animate([
        {transform:`translateX(${previous}px) scale(1,1)`,offset:0,easing:'cubic-bezier(.22,.75,.3,1)'},
        {transform:`translateX(${target + direction*4}px) scale(1.035,.93)`,offset:.65,easing:'ease-out'},
        {transform:`translateX(${target - direction}px) scale(.99,1.02)`,offset:.84,easing:'ease-out'},
        {transform:`translateX(${target}px) scale(1,1)`,offset:1}
      ],{duration:420});
      const motion = lensMotion;
      motion.finished.then(()=>{if(lensMotion===motion){lensMotion=null;lens.dataset.moving='false'}}).catch(()=>{});
      const icon = active.querySelector('.ui-icon');
      iconMotion = icon.animate([
        {transform:'translateY(0) scale(1)',offset:0},
        {transform:'translateY(-4px) scale(1.1)',offset:.4},
        {transform:'translateY(1px) scale(.98)',offset:.72},
        {transform:'translateY(0) scale(1)',offset:1}
      ],{duration:320,easing:'ease-out'});
    } else lensMotion = null;
    current = active.id; initialized = true;
  }
  function schedule(animate){cancelAnimationFrame(frame);frame=requestAnimationFrame(()=>position(animate))}
  new MutationObserver(()=>schedule(true)).observe(nav,{subtree:true,attributes:true,attributeFilter:['aria-current']});
  new MutationObserver(()=>position(false)).observe(document.documentElement,{attributes:true,attributeFilter:['class']});
  new ResizeObserver(()=>schedule(false)).observe(inner);
  reduced.addEventListener('change',()=>position(false));
  nav.addEventListener('pointerdown',()=>nav.classList.add('is-pressing'));
  for(const event of ['pointerup','pointercancel','blur']) window.addEventListener(event,()=>nav.classList.remove('is-pressing'));
  schedule(false);
})();
