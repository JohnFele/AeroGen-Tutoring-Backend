const uuid = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const legacy = /^(?:AG|BIL|ACC|TEC|SAF|CON|QLT|DSP|OTH|BUG)-[0-9]{1,19}$/;
const complete = /^[A-Z]{3}-[A-Z]{3}-[A-Z]{3}-[0-9]{8}T[0-9]{6}Z-[0-9]{1,19}$/;
const prefix = /^[A-Z0-9]+(?:-[A-Z0-9]+)*-?$/;

export function parseSupportSearch({ reference, createdOn }, queue) {
  let match;
  let day;
  if (reference !== undefined && reference !== '') {
    if (typeof reference !== 'string' || reference.length > 64) return null;
    const code = reference.trim().toUpperCase();
    if (!code) return null;
    if (queue === 'enquiries' && uuid.test(code)) match = ['id', code.toLowerCase(), true];
    else if (queue === 'tickets' && legacy.test(code)) match = [code.startsWith('AG-') ? 'reference' : 'category_reference', code, true];
    else if (prefix.test(code) && code.length >= 2) match = ['case_reference', code, complete.test(code)];
    else return null;
  }
  if (createdOn !== undefined && createdOn !== '') {
    if (typeof createdOn !== 'string' || !/^20[0-9]{2}-[0-9]{2}-[0-9]{2}$/.test(createdOn)) return null;
    const start = new Date(`${createdOn}T00:00:00.000Z`);
    if (!Number.isFinite(start.getTime()) || start.toISOString().slice(0, 10) !== createdOn) return null;
    day = [start.toISOString(), new Date(start.getTime() + 86400000).toISOString()];
  }
  return { match, day };
}

export function applySupportSearch(query, { match, day }) {
  if (match) {
    const [field, value, exact] = match;
    query = exact ? query.eq(field, value) : query.like(field, `${value}%`);
  }
  if (day) query = query.gte('created_at', day[0]).lt('created_at', day[1]);
  return query;
}
