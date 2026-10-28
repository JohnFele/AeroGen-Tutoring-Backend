import { databaseIssue } from './application.controller.js';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const columns = 'id,first_name,last_name,email,phone,location,bio,is_verified,demo_dataset,created_at,updated_at';
export function validateStudentEdit(body) {
  if (!body || typeof body.expectedUpdatedAt !== 'string' || Number.isNaN(Date.parse(body.expectedUpdatedAt)) || !body.changes || typeof body.changes !== 'object' || Array.isArray(body.changes)) throw new Error('Reload the profile and enter valid student details.');
  const limits = { first_name: 60, last_name: 60, phone: 22, location: 200, bio: 2000 };
  const changes = {};
  for (const [field, value] of Object.entries(body.changes)) {
    if (!Object.hasOwn(limits, field) || typeof value !== 'string' || value.length > limits[field] || (['first_name', 'last_name'].includes(field) && !value.trim())) throw new Error('Enter valid student names, contact details and biography. Roles and login emails cannot be changed here.');
    if (field === 'phone' && value.trim() && !/^\+?[\d\s()-]{9,22}$/.test(value.trim())) throw new Error('Enter a valid phone number with its country code.');
    changes[field] = value.trim();
  }
  if (!Object.keys(changes).length) throw new Error('Enter at least one profile change.');
  return changes;
}
export const listStudents = async (req, res, next) => {
  try {
    const students = [];
    for (let start = 0; ; start += 500) {
      const { data, error } = await req.supabase.from('profiles').select(`${columns},bookings!bookings_student_id_fkey(count)`).eq('role', 'student').order('id').range(start, start + 499).abortSignal(AbortSignal.timeout(15000));
      if (error) throw error;
      students.push(...data);
      if (data.length < 500) break;
    }
    return res.json({ students });
  } catch (error) { return next(error); }
};
export const studentDetails = async (req, res, next) => {
  if (!uuid.test(req.params.id)) return res.status(400).json({ message: 'Invalid student reference.' });
  try {
    const { data: student, error } = await req.supabase.from('profiles').select(columns).eq('role', 'student').eq('id', req.params.id).maybeSingle();
    if (error) throw error;
    if (!student) return res.status(404).json({ message: 'Student not found.' });
    const { data: bookings, error: bookingError } = await req.supabase.from('bookings').select('id,status,starts_at,duration_minutes,total_amount,tutor:tutor_profiles!bookings_tutor_id_fkey(public_name),subject:subjects(name)').eq('student_id', req.params.id).order('starts_at', { ascending: false }).limit(100);
    if (bookingError) throw bookingError;
    return res.json({ student, bookings });
  } catch (error) { return next(error); }
};
export const editStudent = async (req, res, next) => {
  if (!uuid.test(req.params.id)) return res.status(400).json({ message: 'Invalid student reference.' });
  let changes;
  try { changes = validateStudentEdit(req.body); } catch (error) { return res.status(400).json({ message: error.message }); }
  try {
    const { error } = await req.supabase.rpc('admin_update_student', { _id: req.params.id, _patch: changes, _expected_updated_at: req.body.expectedUpdatedAt }).abortSignal(AbortSignal.timeout(15000));
    if (error) { if (databaseIssue(res, error)) return; throw error; }
    const { data, error: readError } = await req.supabase.from('profiles').select(`${columns},bookings!bookings_student_id_fkey(count)`).eq('id', req.params.id).single();
    if (readError) throw readError;
    return res.json({ message: 'Student profile saved.', student: data });
  } catch (error) { return next(error); }
};
