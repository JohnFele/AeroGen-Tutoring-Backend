import { applicationBucket, applicationDocumentTypes } from './applicationFiles.js';

export const applicationFields = {
  firstName: 'first_name', lastName: 'last_name', email: 'contact_email', idNumber: 'id_number',
  phone: 'phone', address: 'street_address', city: 'city', province: 'province',
  highestQualification: 'highest_qualification', institution: 'institution', certifications: 'certifications',
  previousPlatforms: 'previous_platforms', studentAgeGroups: 'student_age_groups', teachingStyle: 'teaching_style',
  availability: 'availability_slots', teachingMode: 'teaching_modes', studentsPerSession: 'students_per_session',
};

const revisionColumns = [
  'id', 'status', ...Object.values(applicationFields), 'year_completed', 'experience_range', 'years_experience', 'hourly_rate',
  'tutor_application_subjects(subjects(name))',
  'tutor_application_documents(id,document_type,storage_path,original_filename,size_bytes)',
].join(',');

export async function readRejectedApplication(req) {
  const { data, error } = await req.supabase.from('tutor_applications')
    .select(revisionColumns).eq('user_id', req.userId)
    .order('created_at', { ascending: false }).order('id', { ascending: false })
    .limit(1).maybeSingle().abortSignal(AbortSignal.timeout(15000));
  if (error) throw error;
  return data?.status === 'rejected' ? data : null;
}

export function publicApplicationRevision(row) {
  if (!row) return null;
  const application = Object.fromEntries(Object.entries(applicationFields)
    .filter(([, column]) => row[column] != null).map(([field, column]) => [field, row[column]]));
  return {
    application: {
      ...application,
      yearCompleted: String(row.year_completed ?? ''),
      yearsExperience: row.experience_range || String(row.years_experience ?? ''),
      hourlyRate: String(row.hourly_rate ?? ''),
      subjects: (row.tutor_application_subjects || []).map(item => item.subjects?.name).filter(Boolean),
    },
    documents: Object.entries(applicationDocumentTypes).flatMap(([kind, type]) => {
      const file = row.tutor_application_documents?.find(item => item.document_type === type);
      return file && file.original_filename && Number(file.size_bytes) > 0
        ? [{ id: file.id, kind, name: file.original_filename, size: Number(file.size_bytes) }]
        : [];
    }),
  };
}

export async function readPreviousDocument(req, rejected, reference) {
  const file = rejected?.tutor_application_documents?.find(item => item.id === reference.previousId &&
    item.document_type === applicationDocumentTypes[reference.kind]);
  if (!file || !file.storage_path?.startsWith(`${req.userId}/`)) {
    throw Object.assign(new Error('This previous document is no longer available for the revision. Reload the application.'), { code: 'REVISION_STALE' });
  }
  const { data, error } = await req.supabase.storage.from(applicationBucket).download(file.storage_path);
  if (error || data.size !== Number(file.size_bytes)) {
    throw Object.assign(new Error(`We could not reuse ${file.original_filename}. Choose a replacement or try again.`), { code: '22023' });
  }
  return { kind: reference.kind, name: file.original_filename, content: Buffer.from(await data.arrayBuffer()).toString('base64') };
}
