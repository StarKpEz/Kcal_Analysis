/* Convert both native result channels through the real, existing parsers before any write. */
(function(scope){
  function mergeNativeHealth(result, parse, range) {
    if (!result || typeof result !== 'object' || !Array.isArray(result.notes) || result.notes.some(note=>typeof note!=='string')) throw new Error('健康读取结果无效');
    if(range && result.daily?.days?.some(day=>day.date<range.from || day.date>range.through)) throw new Error('健康返回日期超出所选范围');
    if(range && result.sleepSamples && (result.sleepSamples.from!==range.from || result.sleepSamples.through!==range.through)) throw new Error('睡眠返回范围与所选日期不一致');
    const fields = {burn:{},training:{},sleep:{},weight:{},weightMeta:{}};
    const notes = [...result.notes];
    for (const value of [result.daily,result.sleepSamples]) {
      if (value == null) continue;
      const parsed = parse(JSON.stringify(value));
      for (const key of Object.keys(fields)) {
        for (const [date,record] of Object.entries(parsed[key] || {})) {
          if (Object.hasOwn(fields[key],date)) throw new Error('同一天健康数据重复，请重新读取');
          fields[key][date] = record;
        }
      }
      if (parsed.notes) notes.push(...parsed.notes);
    }
    if (Object.values(fields).every(group => Object.keys(group).length === 0)) {
      return {fields:null,notes:[...new Set(notes)]};
    }
    fields.notes = [...new Set(notes)];
    return {fields,notes:fields.notes};
  }
  if (typeof module !== 'undefined' && module.exports) module.exports = {mergeNativeHealth};
  else scope.mergeNativeHealth = mergeNativeHealth;
})(globalThis);
