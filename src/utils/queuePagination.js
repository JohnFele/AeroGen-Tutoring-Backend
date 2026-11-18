export function parseQueuePage(query) {
  if(['page','limit'].some(key=>query[key]!==undefined&&typeof query[key]!=='string'))return null;
  const page=Number(query.page||1),limit=Number(query.limit||25);
  if(!Number.isSafeInteger(page)||page<1||page>1000||!Number.isSafeInteger(limit)||limit<1||limit>50)return null;
  return {page,limit,from:(page-1)*limit,to:page*limit-1};
}
