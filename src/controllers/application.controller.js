import { cleanSubmittedDraftFiles } from './applicationDraft.controller.js';
import { randomUUID } from 'node:crypto';
import { validateApplication } from './site.controller.js';

const bucket = 'tutor-application-documents';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const fields = {
  firstName: 'first_name', lastName: 'last_name', email: 'contact_email', idNumber: 'id_number',
  phone: 'phone', address: 'street_address', city: 'city', province: 'province',
  highestQualification: 'highest_qualification', institution: 'institution', certifications: 'certifications',
  previousPlatforms: 'previous_platforms', studentAgeGroups: 'student_age_groups', teachingStyle: 'teaching_style',
  availability: 'availability_slots', teachingMode: 'teaching_modes', studentsPerSession: 'students_per_session',
};
export function applicationRecord(data) {
  const experience = { '0-1': 0, '1-2': 1, '3-5': 3, '5-10': 5, '10+': 10 };
  const years = Object.hasOwn(experience, data.yearsExperience) ? experience[data.yearsExperience] : Number(data.yearsExperience);
  if (!Number.isFinite(years) || years < 0 || years > 80) throw new Error('Enter valid years of teaching experience.');
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(data.email) || data.email.length > 254) throw new Error('Enter a valid contact email.');
  if (data.firstName.length > 60 || data.lastName.length > 60 || data.idNumber.length > 100 || data.city.length > 160 || data.highestQualification.length > 250 || data.institution.length > 250) throw new Error('Some application details exceed the allowed length.');
  if (!['Eastern Cape','Free State','Gauteng','KwaZulu-Natal','Limpopo','Mpumalanga','North West','Northern Cape','Western Cape'].includes(data.province)) throw new Error('Choose a valid South African province.');
  if (data.teachingMode.some(mode => !['online', 'in-person'].includes(mode))) throw new Error('Choose valid teaching modes.');
  return {
    ...Object.fromEntries(Object.entries(fields).map(([input, column]) => [column, Array.isArray(data[input]) ? [...new Set(data[input].map(item => item.trim()))] : String(data[input] || '').trim()])),
    year_completed: Number(data.yearCompleted), years_experience: years,
    experience_range: Object.hasOwn(experience, data.yearsExperience) ? data.yearsExperience : null,
    hourly_rate: Number(data.hourlyRate),
  };
}
export function databaseIssue(res, error) {
  const status = { '42501': 403, PT409: 409, '23505': 409, P0002: 404, '22023': 400, '23514': 400, '23502': 400, '23503': 400, '22P02': 400, PGRST200: 503, PGRST202: 503, PGRST204: 503, '42703': 503, '42P01': 503 }[error?.code];
  if (!status) return false;
  res.status(status).json({ message: status === 503 ? 'This feature is temporarily unavailable. Please try again later.' : error.code === '23505' ? 'An application is already awaiting review. Reload to see its status.' : error.message });
  return true;
}
export const currentApplication = async (req, res, next) => {
  try {
    const { data, error } = await req.supabase.from('tutor_applications').select('id,status,submitted_at,reviewed_at,review_notes,updated_at').eq('user_id', req.userId).order('created_at', { ascending: false }).limit(1).maybeSingle();
    if (error) throw error;
    return res.json({ application: data });
  } catch (error) { return next(error); }
};
export const submitApplication = async (req, res, next) => {
  let record, validated;
  const id = req.body?.submissionId || randomUUID();
  if (!uuid.test(id)) return res.status(400).json({ message: 'Invalid submission reference. Reload the form.' });
  try { validated = validateApplication(req.body); record = applicationRecord(req.body.application); }
  catch (error) { return res.status(400).json({ message: error.message }); }
  const uploaded = [];
  let stored = false;
  try {
    const { data: existing, error: existingError } = await req.supabase.from('tutor_applications').select('id,status,first_name,experience_range').eq('id', id).eq('user_id', req.userId).maybeSingle();
    if (existingError) throw existingError;
    if (existing) { await cleanSubmittedDraftFiles(req); return res.status(200).json({ message: 'Your application is already saved in the review portal.', applicationId: existing.id, status: existing.status }); }
    const { data: open, error: openError } = await req.supabase.from('tutor_applications').select('id').eq('user_id', req.userId).in('status', ['submitted', 'under_review']).limit(1);
    if (openError) throw openError;
    if (open.length) return res.status(409).json({ message: 'You already have an application awaiting review. Reload to see its status.' });
    const { data: subjects, error: subjectError } = await req.supabase.from('subjects').select('id,name').eq('is_active', true).in('name', req.body.application.subjects);
    if (subjectError) throw subjectError;
    if (subjects.length !== new Set(req.body.application.subjects).size) return res.status(400).json({ message: 'Choose current subjects from the subject catalogue.' });
    const documents = [];
    for (let index = 0; index < req.body.documents.length; index++) {
      const input = req.body.documents[index];
      const attachment = validated.attachments[index];
      const bytes = Buffer.from(attachment.content, 'base64');
      const ext = attachment.name.split('.').at(-1).toLowerCase();
      const mime = ext === 'pdf' ? 'application/pdf' : ext === 'png' ? 'image/png' : ext === 'docx' ? 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' : 'image/jpeg';
      const path = `${req.userId}/${id}/${randomUUID()}-${attachment.name}`;
      const { error } = await req.supabase.storage.from(bucket).upload(path, bytes, { contentType: mime, upsert: false });
      if (error) throw error;
      uploaded.push(path);
      documents.push({ document_type: { idDocument: 'identity', qualificationDocument: 'qualification', resume: 'resume' }[input.kind], storage_path: path, original_filename: input.name, mime_type: mime, size_bytes: bytes.length });
    }
    const { data, error } = await req.supabase.rpc(req.applicationDraft?'submit_tutor_application_draft':'submit_tutor_application', { _id: id, _data: record, _subjects: subjects.map(subject => subject.id), _documents: documents, ...(req.applicationDraft?{_draft_version:req.applicationDraft.version}:{}) }).abortSignal(AbortSignal.timeout(15000));
    if (error) throw error;
    stored = true;
    await cleanSubmittedDraftFiles(req);
    return res.status(201).json({ message: 'Your application and private documents have been saved. The AeroGen team will review them in the admin portal.', applicationId: data, status: 'submitted' });
  } catch (error) {
    // An interrupted response can occur after commit. Confirm before removing uploads.
    if (uploaded.length) {
      const { data } = await req.supabase.from('tutor_applications').select('id').eq('id', id).eq('user_id', req.userId).maybeSingle();
      if (data) { stored = true; await cleanSubmittedDraftFiles(req); return res.status(200).json({ message: 'Your application is saved in the review portal.', applicationId: id, status: 'submitted' }); }
    }
    if (databaseIssue(res, error)) return;
    return next(error);
  } finally {
    if (!stored && uploaded.length) {
      const { error } = await req.supabase.storage.from(bucket).remove(uploaded);
      if (error) console.error('Could not clean up unattached application uploads:', error.message);
    }
  }
};

export const applicationColumns = '*,profiles!tutor_applications_user_id_fkey(id,first_name,last_name,email,role,demo_dataset),tutor_application_subjects(subjects(id,name)),tutor_application_documents(id,document_type,original_filename,mime_type,size_bytes),tutor_application_reviews(id,status,previous_status,notes,created_at)';
export const listApplications = async (req, res, next) => {
  try {
    const rows = [];
    for (let start = 0; ; start += 100) {
      const { data, error } = await req.supabase.from('tutor_applications').select(applicationColumns).order('created_at', { ascending: false }).order('id').range(start, start + 99).abortSignal(AbortSignal.timeout(15000));
      if (error) throw error;
      rows.push(...data);
      if (data.length < 100) break;
    }
    return res.json({ applications: rows });
  } catch (error) { if (databaseIssue(res,error)) return; return next(error); }
};
export const reviewApplication = async (req, res, next) => {
  const { status, notes, expectedUpdatedAt } = req.body || {};
  if (!uuid.test(req.params.id) || !['under_review', 'approved', 'rejected'].includes(status) || typeof notes !== 'string' || notes.length > 4000 || (status === 'rejected' && notes.trim().length < 5) || typeof expectedUpdatedAt !== 'string' || Number.isNaN(Date.parse(expectedUpdatedAt))) return res.status(400).json({ message: 'Choose a decision, include review notes (required for rejection), and reload the current application before saving.' });
  try {
    const { data: tutorId, error } = await req.supabase.rpc('review_tutor_application', { _id: req.params.id, _status: status, _notes: notes.trim(), _expected_updated_at: expectedUpdatedAt }).abortSignal(AbortSignal.timeout(15000));
    if (error) { if (databaseIssue(res, error)) return; throw error; }
    const { data, error: readError } = await req.supabase.from('tutor_applications').select(applicationColumns).eq('id', req.params.id).single();
    if (readError) throw readError;
    return res.json({ message: status === 'approved' ? 'Application approved. The tutor profile is published and tutor dashboard access is enabled.' : 'Application review saved.', application: data, tutorId });
  } catch (error) { return next(error); }
};
export const applicationDocument = async (req, res, next) => {
  if (!uuid.test(req.params.id) || !uuid.test(req.params.documentId)) return res.status(400).json({ message: 'Invalid document reference.' });
  try {
    const { data, error } = await req.supabase.from('tutor_application_documents').select('storage_path,original_filename').eq('id', req.params.documentId).eq('application_id', req.params.id).maybeSingle();
    if (error) throw error;
    if (!data) return res.status(404).json({ message: 'Document not found.' });
    const { data: signed, error: signError } = await req.supabase.storage.from(bucket).createSignedUrl(data.storage_path, 60, { download: data.original_filename || true });
    if (signError) throw signError;
    res.set('Cache-Control', 'no-store');
    return res.json({ url: signed.signedUrl, expiresIn: 60 });
  } catch (error) { return next(error); }
};
