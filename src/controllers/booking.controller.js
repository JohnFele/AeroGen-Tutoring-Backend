import { createPublicSupabaseClient } from '../config/supabase.js';
import { isBookingSchemaUnavailable } from '../utils/bookingSchema.js';
import { applySupportSearch, parseSupportSearch } from '../utils/supportSearch.js';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const durations = [30, 60, 90, 120];
const categories = ['safety', 'conduct', 'lesson_quality', 'other'];
const bad = (res, message) => res.status(400).json({ message });

function fail(error, res, next) {
  if (isBookingSchemaUnavailable(error)) {
    return res.status(503).json({
      code: 'BOOKING_SCHEMA_UNAVAILABLE',
      message: 'Private booking services are temporarily unavailable.',
    });
  }
  const status = { '42501': 403, '22023': 400, PT404: 404, PT409: 409, PT503: 503 }[error.code];
  return status ? res.status(status).json({ message: error.message }) : next(error);
}

async function rpc(client, name, args, res, next, format, status = 200) {
  try {
    const { data, error } = await client.rpc(name, args).abortSignal(AbortSignal.timeout(15000));
    if (error) return fail(error, res, next);
    return res.status(status).json(format(data));
  } catch (error) { return next(error); }
}

export function tutorSlots(req, res, next) {
  const duration = Number(req.query.duration || 60);
  if (!uuid.test(req.params.id) || !durations.includes(duration)) return bad(res, 'Choose a tutor and lesson duration.');
  res.set('Cache-Control', 'no-store');
  return rpc(createPublicSupabaseClient(), 'booking_slot_options', { _tutor: req.params.id, _student: null, _duration: duration }, res, next, data => data);
}

export function matchingSlots(req, res, next) {
  const { tutorId, studentId = req.userId } = req.query;
  const duration = Number(req.query.duration || 60);
  if (!uuid.test(tutorId) || !uuid.test(studentId) || !durations.includes(duration)) return bad(res, 'Choose the participants and a valid duration.');
  res.set('Cache-Control', 'no-store');
  return rpc(req.supabase, 'booking_slot_options', { _tutor: tutorId, _student: studentId, _duration: duration }, res, next, data => data);
}

export function tutorsAtTime(req, res, next) {
  const { startsAt } = req.query;
  const duration = Number(req.query.duration || 60);
  if (typeof startsAt !== 'string' || startsAt.length > 35 || !Number.isFinite(Date.parse(startsAt)) || !durations.includes(duration)) {
    return bad(res, 'Choose a date, time and valid lesson duration.');
  }
  res.set('Cache-Control', 'no-store');
  return rpc(req.supabase || createPublicSupabaseClient(), 'tutors_available_at', { _starts: startsAt, _duration: duration }, res, next, ids => ({ ids }));
}

export function bookableStudents(req, res, next) {
  const term = typeof req.query.q === 'string' ? req.query.q.trim() : '';
  if (term.length < 2 || term.length > 80) return bad(res, 'Enter a name or booking code.');
  res.set('Cache-Control', 'no-store');
  return rpc(req.supabase, 'search_bookable_students', { _query: term }, res, next, students => ({ students }));
}

export function bookingHours(req, res, next) {
  res.set('Cache-Control', 'no-store');
  return rpc(req.supabase, 'my_booking_availability', {}, res, next, data => data);
}

function validDate(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const time = Date.parse(`${value}T00:00:00Z`);
  return Number.isFinite(time) && new Date(time).toISOString().slice(0,10) === value;
}

export function bookingDay(req, res, next) {
  if (!validDate(req.query.date)) return bad(res, 'Choose a valid date.');
  res.set('Cache-Control', 'no-store');
  return rpc(req.supabase, 'my_booking_day', { _day: req.query.date }, res, next, data => data);
}

export function bookingMonth(req, res, next) {
  if (!validDate(req.query.date)) return bad(res, 'Choose a valid month.');
  return rpc(req.supabase, 'my_booking_month', { _month: req.query.date }, res, next, data => data);
}

export function saveBookingDay(req, res, next) {
  const { date, mode, start, end } = req.body || {};
  if (!validDate(date) || !['weekly','custom','closed'].includes(mode) ||
    (mode === 'custom' && (!Number.isInteger(start) || !Number.isInteger(end) || start < 0 || end > 1440 || start >= end || start % 30 || end % 30))) {
    return bad(res, 'Choose a date and valid availability hours.');
  }
  return rpc(req.supabase, 'save_booking_day', { _day: date, _mode: mode, _start: mode === 'custom' ? start : null,
    _end: mode === 'custom' ? end : null }, res, next, data => data);
}

export function saveBookingHours(req, res, next) {
  const { hours, discoverable = false } = req.body || {};
  const valid = row => row && Number.isInteger(row.weekday) && row.weekday >= 1 && row.weekday <= 7
    && Number.isInteger(row.start_minute) && Number.isInteger(row.end_minute)
    && row.start_minute % 30 === 0 && row.end_minute % 30 === 0
    && row.start_minute >= 0 && row.end_minute <= 1440 && row.start_minute < row.end_minute;
  if (typeof discoverable !== 'boolean' || !Array.isArray(hours) || hours.length > 7 || !hours.every(valid) || new Set(hours.map(row => row.weekday)).size !== hours.length) {
    return bad(res, 'Choose one valid time range per day.');
  }
  return rpc(req.supabase, 'save_booking_availability', { _hours: hours, _discoverable: discoverable }, res, next, () => ({ hours, discoverable }));
}

export function requestBooking(req, res, next) {
  const { tutorId, studentId = req.userId, subjectId, startsAt, duration, mode, type, notes = '', curriculumCode } = req.body || {};
  if (!uuid.test(tutorId) || !uuid.test(studentId) || !Number.isSafeInteger(subjectId) || subjectId < 1 ||
    typeof startsAt !== 'string' || !Number.isFinite(Date.parse(startsAt)) || !durations.includes(duration) ||
    !['online', 'in-person'].includes(mode) || !['individual', 'small-group', 'medium-group'].includes(type) ||
    typeof notes !== 'string' || notes.length > 2000 ||
    (curriculumCode !== undefined && (typeof curriculumCode !== 'string' || curriculumCode.length > 60 ||
      !/^[a-z0-9]+(-[a-z0-9]+)*$/.test(curriculumCode)))) return bad(res, 'Choose a subject, available time, teaching format and duration.');
  return rpc(req.supabase, 'request_tutoring_booking', {
    _tutor: tutorId, _student: studentId, _subject: subjectId, _starts_at: startsAt, _duration: duration,
    _mode: mode, _type: type, _notes: notes.trim(),
    ...(curriculumCode ? { _curriculum: curriculumCode } : {}),
  }, res, next, id => ({ id }), 201);
}

export function respondToBooking(req, res, next) {
  const { action } = req.body || {};
  if (!uuid.test(req.params.id) || !['accept', 'decline', 'cancel', 'complete'].includes(action)) return bad(res, 'Choose a booking action.');
  return rpc(req.supabase, 'respond_to_tutoring_booking', { _booking: req.params.id, _action: action }, res, next, status => ({ status }));
}

export function reportBooking(req, res, next) {
  const { category, description } = req.body || {};
  if (!uuid.test(req.params.id) || !categories.includes(category) || typeof description !== 'string' || description.trim().length < 20 || description.length > 2000) {
    return bad(res, 'Choose a category and describe the concern in 20 to 2,000 characters.');
  }
  return rpc(req.supabase, 'report_booking_ticket', { _booking: req.params.id, _category: category, _description: description.trim() },
    res, next, ticket => ({ id: ticket.id, reference: ticket.case_reference || ticket.category_reference || ticket.reference }), 201);
}

export async function listSafetyCases(req, res, next) {
  const status = req.query.status || 'new';
  const developer = req.query.queue === 'developer';
  if (developer && req.userRole !== 'superUser') return res.status(403).json({ message: 'Only superusers can access the developer queue.' });
  if (!['all', 'new', 'investigating', 'waiting', 'resolved'].includes(status)) return bad(res, 'Choose a case status.');
  const page = Number(req.query.page || 1);
  if (!Number.isSafeInteger(page) || page < 1 || page > 1000) return bad(res, 'Choose a valid page.');
  const search = parseSupportSearch(req.query, 'tickets');
  if (!search) return bad(res, 'Enter a valid ticket reference, prefix, or UTC date.');
  const { reporter, category, issue } = req.query;
  if (reporter !== undefined && !['student','tutor','admin','unknown'].includes(reporter)) return bad(res, 'Choose a valid reporter type.');
  if (category !== undefined && ![...categories,'billing','account','technical','lesson_dispute','bug'].includes(category)) return bad(res, 'Choose a valid ticket category.');
  if (issue !== undefined && (typeof issue !== 'string' || !/^[A-Z]{3}$/.test(issue))) return bad(res, 'Choose a valid issue code.');
  if (req.query.scope !== undefined && req.query.scope !== 'mine') return bad(res, 'Choose a valid ticket assignment filter.');
  try {
    let query = req.supabase.from('booking_safety_cases').select('id,category,status,created_at,updated_at,reference:case_reference,reporter_kind,issue_code,subject,response_due_at,version,auto_resolved_at,developer_status', { count: 'exact' });
    if (developer) query = query.not('developer_status', 'is', null);
    if (status !== 'all') query = query.eq(developer ? 'developer_status' : 'status', status);
    if (req.query.scope === 'mine') query = query.eq('assigned_to', req.userId);
    if (reporter) query = query.eq('reporter_kind', reporter);
    if (category) query = query.eq('category', category);
    if (issue) query = query.eq('issue_code', issue);
    query = applySupportSearch(query, search);
    if (!developer && req.query.order === 'due') query = query.order('response_due_at', { nullsFirst: false });
    const { data, count, error } = await query.order('created_at', { ascending: false }).order('id')
      .range((page - 1) * 25, page * 25 - 1).abortSignal(AbortSignal.timeout(15000));
    if (error) return fail(error, res, next);
    return res.json({ cases: data, total: count });
  } catch (error) { return next(error); }
}

export function openSafetyCase(req, res, next) {
  if (!uuid.test(req.params.id)) return bad(res, 'Choose a safety case.');
  return rpc(req.supabase, 'open_booking_safety_case', { _case: req.params.id }, res, next, safetyCase => ({ safetyCase }));
}

export function reviewSafetyCase(req, res, next) {
  const { status, version, outcome = '' } = req.body || {};
  if (!uuid.test(req.params.id) || !['investigating', 'resolved'].includes(status) || !Number.isSafeInteger(version) || version < 1 ||
    typeof outcome !== 'string' || outcome.length > 2000 || (status === 'resolved' && outcome.trim().length < 20)) return bad(res, 'Enter a valid status and resolution.');
  return rpc(req.supabase, 'review_booking_safety_case', { _case: req.params.id, _status: status, _outcome: outcome.trim(), _version: version }, res, next, () => ({ status }));
}
