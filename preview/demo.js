// Fictional examples only. Every reload creates a new, isolated in-memory store.
const previewStorage = (() => {
  const memory = new Map();
  const localDay = offset => {
    const date = new Date(); date.setDate(date.getDate() + offset);
    return date.toLocaleDateString('sv-SE');
  };
  const now = new Date().toISOString();
  const data = {
    app:'kcal', version:7, entries:{},
    settings:{kcal:2100,p:115,f:65,c:260},
    body:{sex:'female',birthYear:1990,heightCm:170,bodyFat:'',activity:1.375,weightKg:'',preferHarris:false},
    weight:{}, weightMeta:{}, burn:{}, training:{}, sleep:{}, completion:{}, meta:{lastBackup:localDay(0)}
  };
  for (let offset = -56; offset <= 0; offset++) {
    const day = localDay(offset);
    const progress = (offset + 56) / 56;
    if (offset % 5 !== -2) {
      data.weight[day] = Math.round((80.4 - progress * 2.2 + Math.sin(offset * 1.7) * .18) * 10) / 10;
      data.weightMeta[day] = {source:'health-json',updatedAt:now,measuredAt:day+'T07:30:00+08:00'};
    }
    data.burn[day] = {active:480+Math.abs(offset%7)*22,basal:1450,source:'health-json',updatedAt:now};
    data.entries[day] = {
      breakfast:[{name:'燕麦与酸奶',kcal:360,protein:19,fat:10,carbs:48}],
      lunch:[{name:'鸡肉蔬菜饭',kcal:580,protein:38,fat:18,carbs:65}],
      dinner:offset===0?[]:[{name:'豆腐与杂粮',kcal:520,protein:28,fat:16,carbs:61}],
      snack:[{name:'水果与坚果',kcal:180,protein:4,fat:8,carbs:23}]
    };
    data.training[day] = {sessions:[{id:'demo-walk-'+day,type:'户外步行',durationMinutes:35,distanceKm:3.6,energyKcal:230,startAt:day+'T08:30:00+08:00'}],source:'health-json',updatedAt:now};
    data.sleep[day] = {asleepMinutes:420,startAt:localDay(offset-1)+'T23:15:00+08:00',endAt:day+'T06:30:00+08:00',stages:{core:285,deep:60,rem:75},source:'health-json',updatedAt:now};
  }
  memory.set('kcal.data.v5', JSON.stringify(data));
  return Object.freeze({
    getItem:key => memory.has(String(key)) ? memory.get(String(key)) : null,
    setItem:(key,value) => memory.set(String(key),String(value)),
    removeItem:key => memory.delete(String(key)), clear:() => memory.clear()
  });
})();
window.fetch = () => Promise.reject(new Error('预览仅使用演示数据，不发送网络请求。'));
