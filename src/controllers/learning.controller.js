import { isBookingSchemaUnavailable } from '../utils/bookingSchema.js';

const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
const actions = new Set([
  'enable','startPlan','approveAccess','declineAccess','revokeAccess','saveGoal','approveGoal','confirmGoal',
  'goalStatus','scheduleReview','assessment','verifyAssessment','correctAssessment','submitEvidence',
  'checkIn','reviewEvidence','addActivity','toggleActivity','feedback','reflection',
]);
const invalid = res => res.status(400).json({ message: 'Check the learning form and try again.' });

async function rpc(req, res, next, name, args) {
  try {
    const { data, error } = await req.supabase.rpc(name, args).abortSignal(AbortSignal.timeout(15000));
    if (error) {
      if (isBookingSchemaUnavailable(error)) return res.status(503).json({ message: 'Learning progress is temporarily unavailable.' });
      const status = { '42501':403, '22023':400, PT404:404, PT409:409, PT429:429, PT503:503 }[error.code];
      return status ? res.status(status).json({ message: error.message }) : next(error);
    }
    res.set('Cache-Control','private, no-store');
    return res.json(data);
  } catch (error) { return next(error); }
}

export function learningProgress(req,res,next) {
  if (req.params.plan && !uuid(req.params.plan)) return invalid(res);
  return rpc(req,res,next,'my_learning_progress',{ _plan: req.params.plan || null });
}

export function markLearningTutorialSeen(req,res,next) {
  return rpc(req,res,next,'mark_learning_tutorial_seen',{});
}

export function learnerAgeProfile(req,res,next) {
  if (req.method === 'GET') return rpc(req,res,next,'my_learner_age_profile',{});
  const birthDate = req.body?.birthDate;
  if (typeof birthDate !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(birthDate)
    || !Number.isFinite(Date.parse(birthDate)) || new Date(birthDate).toISOString().slice(0,10) !== birthDate) {
    return res.status(400).json({ message:'Enter a valid date of birth.' });
  }
  return rpc(req,res,next,'save_my_learner_age_profile',{ _birth_date:birthDate });
}

export function learningAction(req,res,next) {
  const { action,planId,version,requestId,data } = req.body || {};
  if (!actions.has(action) || !uuid(requestId) || !data || typeof data !== 'object' || Array.isArray(data)
    || (!['enable','startPlan'].includes(action) && (!uuid(planId) || !Number.isInteger(version) || version < 1 || version > 2147483647))) {
    return invalid(res);
  }
  return rpc(req,res,next,'apply_learning_action',{
    _action: action,_plan: planId || null,_version: version || null,_request: requestId,_data: data,
  });
}

export function learningHistory(req,res,next) {
  const page = Number(req.query.page ?? 1);
  if (!uuid(req.params.plan) || !Number.isInteger(page) || page < 1 || page > 10000) return invalid(res);
  return rpc(req,res,next,'my_learning_history',{ _plan:req.params.plan,_page:page });
}

export function learningClearance(req,res,next) {
  const action = req.method === 'GET' ? 'view' : req.body?.action;
  const reference = req.body?.reference;
  if (!uuid(req.params.id) || !['view','approve','revoke'].includes(action)
    || (action === 'approve' && (typeof reference !== 'string' || reference.trim().length < 4 || reference.length > 120))) {
    return invalid(res);
  }
  return rpc(req,res,next,'manage_learning_clearance',{ _student:req.params.id,_action:action,_reference:reference || null });
}
