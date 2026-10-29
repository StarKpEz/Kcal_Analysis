/* Native-only platform boundary. The PWA never loads this file. */
(() => {
  const pending = new Map();
  const session = Array.from(crypto.getRandomValues(new Uint32Array(4)),value=>value.toString(16)).join('-');
  let serial = 0, lastRaw = null;
  const available = () => !!window.webkit?.messageHandlers?.kcalNative;
  const api = window.KcalNative = {
    available,
    call(method, params = {}) {
      if (!available()) return Promise.reject(new Error('此功能需要在 iOS App 中使用'));
      const id = session + ':' + (++serial);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(new Error('操作超时，请重试')); }, 180000);
        pending.set(id, {resolve,reject,timer});
        try { window.webkit.messageHandlers.kcalNative.postMessage({id,method,params}); }
        catch(error) { clearTimeout(timer); pending.delete(id); reject(error); }
      });
    },
    receive(message) {
      const task = pending.get(String(message?.id));
      if (!task) return;
      pending.delete(String(message.id)); clearTimeout(task.timer);
      if (message.error) task.reject(Object.assign(new Error(message.error.message || '原生操作失败'), {code:message.error.code}));
      else task.resolve(message.result);
    }
  };
  function storage(operation, extra = {}) {
    if (!available()) throw new Error('App 原生存储桥不可用，已停止保存');
    const response = window.prompt('__KCAL_STORAGE__', JSON.stringify({operation,...extra}));
    let reply;
    try { reply = JSON.parse(response); } catch { throw new Error('原生存储没有确认保存'); }
    if (!reply?.ok) throw new Error(reply?.message || '原生存储操作失败');
    return reply;
  }
  // Synchronous native atomic IO preserves the existing commitData rollback and CAS contract.
  window.nativeStorage = Object.freeze({
    getItem(key) {
      if (key !== 'kcal.data.v5') return null;
      const result = storage('read');
      if (result.raw !== null && typeof result.raw !== 'string') throw new Error('本地快照格式无效');
      lastRaw = result.raw; return lastRaw;
    },
    setItem(key,value) {
      if (key !== 'kcal.data.v5') throw new Error('不支持的存储键');
      const raw = String(value);
      storage('write',{raw,expectedRaw:lastRaw});
      lastRaw = raw;
    }
  });
})();
