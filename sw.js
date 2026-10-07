/* 热量记账 · Service Worker
   设计要点（针对 iOS 主屏幕 PWA 的坑）：
   1) HTML / 导航请求一律「网络优先」—— 只要联网就拿到最新版，不需要用户做任何操作
   2) 其他静态资源「缓存优先」，快且省流量
   3) install 完整缓存页面后 skipWaiting；activate 时 clients.claim
   4) 离线时回退缓存，所以断网依然可用 */
const CACHE = 'kcal-v11';

/* 安装时缓存完整应用，成功后才接管并删除旧缓存；导航仍始终网络优先。 */
const SHELL = [
  './index.html',
  './manifest.webmanifest',
  './icons/apple-touch-icon-v3.png',
  './icons/icon-192-v3.png',
  './icons/icon-512-v3.png'
];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => c.addAll(SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

/* 供页面「立即更新」调用 */
self.addEventListener('message', e => {
  if (e.data === 'SKIP_WAITING') self.skipWaiting();
});

function isHTML(req){
  return req.mode === 'navigate' ||
         (req.headers.get('accept') || '').indexOf('text/html') !== -1;
}

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;

  let url;
  try { url = new URL(req.url); } catch (err) { return; }
  if (url.origin !== self.location.origin) return;   // 外部请求不插手

  // ---- HTML：网络优先，失败回退缓存 ----
  if (isHTML(req)) {
    e.respondWith(
      fetch(req)
        .then(res => {
          if (res && res.status === 200) {
            const copy = res.clone();
            caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
          }
          return res;
        })
        .catch(() => caches.match(req).then(hit => hit || caches.match('./index.html')))
    );
    return;
  }

  // ---- 其他资源：缓存优先 ----
  e.respondWith(
    caches.match(req).then(hit => {
      if (hit) return hit;
      return fetch(req).then(res => {
        if (res && res.status === 200 && res.type === 'basic') {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
        }
        return res;
      }).catch(() => hit);
    })
  );
});
