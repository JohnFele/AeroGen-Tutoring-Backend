const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const stringLimits = { public_name: 160, bio: 4000, city: 160, province: 160, qualification: 250, institution: 250, certifications: 2000, teaching_style: 4000, students_per_session: 20, avatar_url: 2048 };
const boolFields = new Set(['is_approved','is_accepting_students','is_featured']);
const arrayFields = new Set(['student_age_groups','availability_slots','teaching_modes']);
const numericFields = { hourly_rate: [1,10000], years_experience: [0,80], year_completed: [1900,new Date().getFullYear()] };

export function validateTutorEdit(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body) || Object.keys(body).some(key => !['changes','subjectIds','expectedUpdatedAt'].includes(key))) throw new Error('Send tutor changes, subject IDs and the last update timestamp.');
  if (!body.changes || typeof body.changes !== 'object' || Array.isArray(body.changes)) throw new Error('Tutor changes must be an object.');
  if (typeof body.expectedUpdatedAt !== 'string' || Number.isNaN(Date.parse(body.expectedUpdatedAt))) throw new Error('Reload the tutor before saving.');
  const changes = {};
  for (const [field,value] of Object.entries(body.changes)) {
    if (Object.hasOwn(stringLimits,field)) {
      if (value === null && !['public_name','bio'].includes(field)) { changes[field]=null; continue; }
      if (typeof value !== 'string' || value.length > stringLimits[field]) throw new Error(`Enter a valid ${field.replaceAll('_',' ')} (up to ${stringLimits[field]} characters).`);
      if (field === 'public_name' && value.trim().length < 2) throw new Error('Enter a public name of at least 2 characters.');
      if (field === 'avatar_url' && value && !/^https:\/\//i.test(value)) throw new Error('Use an HTTPS avatar URL.');
      changes[field] = field === 'avatar_url' ? value.trim() || null : value.trim();
    } else if (boolFields.has(field)) {
      if (typeof value !== 'boolean') throw new Error(`Choose a valid ${field.replaceAll('_',' ')} value.`);
      changes[field]=value;
    } else if (arrayFields.has(field)) {
      if (!Array.isArray(value) || value.length>30 || value.some(item => typeof item!=='string' || !item.trim() || item.length>100)) throw new Error(`Enter valid ${field.replaceAll('_',' ')}.`);
      if (field==='teaching_modes' && value.some(item => !['online','in-person'].includes(item))) throw new Error('Choose online or in-person teaching.');
      changes[field]=[...new Set(value.map(item => item.trim()))];
    } else if (Object.hasOwn(numericFields,field)) {
      if (value===null) { changes[field]=null; continue; }
      const [min,max]=numericFields[field];
      if (typeof value!=='number' || !Number.isFinite(value) || value<min || value>max || (field==='year_completed' && !Number.isInteger(value))) throw new Error(`Enter ${field.replaceAll('_',' ')} between ${min} and ${max}.`);
      changes[field]=value;
    } else throw new Error(`Unsupported tutor field: ${field}`);
  }
  let subjectIds=null;
  if (body.subjectIds !== undefined) {
    if (!Array.isArray(body.subjectIds) || body.subjectIds.length>100 || body.subjectIds.some(id => !Number.isSafeInteger(id) || id<=0)) throw new Error('Choose up to 100 valid subject IDs.');
    subjectIds=[...new Set(body.subjectIds)];
  }
  if (!Object.keys(changes).length && subjectIds===null) throw new Error('Provide at least one change.');
  return { changes, subjectIds, expectedUpdatedAt:body.expectedUpdatedAt };
}

async function allRows(client,table,columns,key='id') {
  const rows=[];
  for (let start=0;;start+=500) {
    const {data,error}=await client.from(table).select(columns).order(key).range(start,start+499).abortSignal(AbortSignal.timeout(15000));
    if(error) throw error;
    rows.push(...data);
    if(data.length<500) return rows;
  }
}
const tutorColumns='*,profiles!tutor_profiles_user_id_fkey(id,first_name,last_name,email,phone,role),tutor_subjects(subjects(id,name,slug))';
export const tutorAudit=async(req,res,next)=>{
  if(!uuid.test(req.params.id))return res.status(400).json({message:'Invalid tutor ID.'});
  try{const {data,error}=await req.supabase.from('tutor_profile_audit').select('id,actor_id,created_at,before_data,after_data,profiles!tutor_profile_audit_actor_id_fkey(first_name,last_name)').eq('tutor_id',req.params.id).order('created_at',{ascending:false}).limit(20);if(error)throw error;return res.json({audit:data});}catch(error){return next(error);}
};
export const listAdminTutors=async(req,res,next)=>{
  try { const tutors=await allRows(req.supabase,'tutor_profiles',tutorColumns,'user_id'); return res.json({tutors}); } catch(error){return next(error);}
};
export const editAdminTutor=async(req,res,next)=>{
  if(!uuid.test(req.params.id)) return res.status(400).json({message:'Invalid tutor ID.'});
  let edit;
  try {edit=validateTutorEdit(req.body);} catch(error){return res.status(400).json({message:error.message});}
  try {
    const {error}=await req.supabase.rpc('admin_update_tutor',{_tutor_id:req.params.id,_patch:edit.changes,_subject_ids:edit.subjectIds,_expected_updated_at:edit.expectedUpdatedAt}).abortSignal(AbortSignal.timeout(15000));
    if(error){
      const status=({'42501':403,'PT409':409,'P0002':404,'22023':400,'23514':400,'23502':400,'23503':400})[error.code];
      if(status) return res.status(status).json({message:status===400 ? error.message : status===409 ? 'This tutor changed while you were editing. Reload the latest profile before saving.' : status===404 ? 'Tutor not found.' : 'Administrator access required.'});
      throw error;
    }
    const {data,error:readError}=await req.supabase.from('tutor_profiles').select(tutorColumns).eq('user_id',req.params.id).single();
    if(readError) throw readError;
    return res.json({message:'Tutor profile saved.',tutor:data});
  } catch(error){return next(error);}
};
export const adminData=async(req,res,next)=>{
  try {
    const [users,tutors,bookings,payments,applications]=await Promise.all([
      allRows(req.supabase,'profiles','id,first_name,last_name,email,role,is_verified,demo_dataset,created_at'),
      allRows(req.supabase,'tutor_profiles',tutorColumns,'user_id'),
      allRows(req.supabase,'bookings','*,student:profiles!bookings_student_id_fkey(first_name,last_name),tutor:tutor_profiles!bookings_tutor_id_fkey(public_name),subject:subjects!bookings_subject_id_fkey(name)'),
      allRows(req.supabase,'payments','id,booking_id,status,amount,platform_fee,provider,created_at'),
      allRows(req.supabase,'tutor_applications','id,user_id,status,highest_qualification,submitted_at,reviewed_at,created_at'),
    ]);
    return res.json({users,tutors,bookings,payments,applications});
  } catch(error){return next(error);}
};
