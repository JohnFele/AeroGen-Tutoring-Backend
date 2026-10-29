export const applicationBucket='tutor-application-documents';
export const documentKinds=['idDocument','qualificationDocument','resume'];
export function decodeApplicationFile(file) {
  if(!documentKinds.includes(file?.kind))throw new Error('Choose a valid document type.');
  const max=(file.kind==='qualificationDocument'?10:5)*1024*1024;
  if(typeof file.content!=='string'||file.content.length>Math.ceil(max/3)*4||!/^[A-Za-z0-9+/]+={0,2}$/.test(file.content))throw new Error('A document is invalid or exceeds its size limit.');
  const bytes=Buffer.from(file.content,'base64');
  if(!bytes.length||bytes.length>max||bytes.toString('base64')!==file.content)throw new Error('A document is invalid or exceeds its size limit.');
  const name=typeof file.name==='string'?file.name.trim().slice(0,120).replace(/[^a-zA-Z0-9._-]/g,'_'):'';
  if(!name)throw new Error('Choose a document with a valid filename.');
  let mime;
  if(/\.pdf$/i.test(name)&&bytes.subarray(0,5).toString()==='%PDF-')mime='application/pdf';
  else if(/\.png$/i.test(name)&&bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])))mime='image/png';
  else if(/\.jpe?g$/i.test(name)&&bytes[0]===255&&bytes[1]===216&&bytes[2]===255)mime='image/jpeg';
  else if(file.kind==='resume'&&/\.docx$/i.test(name)&&bytes.subarray(0,2).toString()==='PK'&&bytes.includes(Buffer.from('word/')))mime='application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  else throw new Error('Use PDF, JPG or PNG documents, or DOCX for your CV. File content must match its extension.');
  return {name,uploadName:`${file.kind}-${name}`,bytes,mime};
}
