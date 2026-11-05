import { isBookingSchemaUnavailable } from '../utils/bookingSchema.js';

const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
const text = (value, min, max) => typeof value === 'string' && value.trim().length >= min && value.length <= max;
const invalid = res => res.status(400).json({ message: 'Check the supplied details and try again.' });

function route(name, validate, format = data => data) {
  return async (req, res, next) => {
    const args = validate(req.body || {}, req.params, req.query);
    if (args === null) return invalid(res);
    try {
      const { data, error } = await req.supabase.rpc(name, args).abortSignal(AbortSignal.timeout(15000));
      if (error) {
        if (isBookingSchemaUnavailable(error)) return res.status(503).json({ message: 'Billing and ticketing are waiting for the database migration.' });
        const status = { '42501': 403, '22023': 400, PT404: 404, PT409: 409, PT429: 429, PT503: 503 }[error.code];
        return status ? res.status(status).json({ message: error.message }) : next(error);
      }
      res.set('Cache-Control', 'no-store');
      return res.json(format(data));
    } catch (error) { return next(error); }
  };
}

const simulation = body => uuid(body.requestId) && typeof body.success === 'boolean';
const paymentArgs = body => ({ _succeeds: body.success, _request: body.requestId });
const displayTicketReference = ({ case_reference, category_reference, ...ticket }) => ({ ...ticket, reference: case_reference || category_reference || ticket.reference });
export const billingOverview = route('my_account_billing', () => ({}));
export const changePlan = route('change_membership', body => simulation(body) && text(body.plan, 2, 30)
  ? { _plan: body.plan, ...paymentArgs(body) } : null);
const cents = value => Number.isSafeInteger(value) && value >= 0 && value <= 2147483647;
export const confirmPlan = route('confirm_membership_change', body => {
  const quote = body.expected;
  if (!simulation(body) || !text(body.plan, 2, 30) || !quote || !uuid(quote.owner) || !text(quote.plan, 2, 30)
    || (quote.nextPlan !== null && !text(quote.nextPlan, 2, 30))
    || (quote.periodEnd !== null && (!text(quote.periodEnd, 10, 40) || !Number.isFinite(Date.parse(quote.periodEnd))))
    || !cents(quote.dueCents) || !cents(quote.renewalCents)) return null;
  return {
    _plan: body.plan, ...paymentArgs(body), _expected_owner: quote.owner, _expected_plan: quote.plan, _expected_next_plan: quote.nextPlan,
    _expected_period_end: quote.periodEnd, _expected_due_cents: quote.dueCents, _expected_renewal_cents: quote.renewalCents,
  };
});
export const subscriptionReceipt = route('my_subscription_receipt', (_body, params) => uuid(params.id) ? { _receipt: params.id } : null);
export const renewalSimulation = route('set_mock_renewal_result', body => typeof body.success === 'boolean' ? { _succeeds: body.success } : null, () => ({ saved: true }));
export const checkoutLesson = route('checkout_booking', (body, params) => uuid(params.id) && simulation(body) && ['checkout','package'].includes(body.source)
  ? { _booking: params.id, _source: body.source, ...paymentArgs(body) } : null);
export const tutorPayout = route('request_tutor_payout', body => simulation(body) && Number.isSafeInteger(body.cents) && body.cents >= 10000 && body.cents <= 2147483647
  ? { _cents: body.cents, ...paymentArgs(body) } : null);
export const lessonOutcome = route('confirm_lesson_outcome', (body, params) => uuid(params.id) && typeof body.happened === 'boolean'
  && text(body.reason || '', body.happened ? 0 : 10, 2000)
  ? { _booking: params.id, _happened: body.happened, _reason: body.reason || '' } : null, status => ({ status }));
export const myTickets = route('my_support_tickets', (_body, _params, query) => {
  const page = Number(query.page ?? 1);
  return Number.isSafeInteger(page) && page >= 1 && page <= 10000 ? { _offset: (page - 1) * 25 } : null;
}, tickets => ({ tickets: tickets.map(displayTicketReference) }));
export const newTicket = route('create_detailed_support_ticket', body => uuid(body.requestId) && ['billing','technical','account','other','bug'].includes(body.category)
  && (body.issue === undefined || text(body.issue,2,30)) && text(body.subject,4,120) && text(body.description,20,2000)
  ? { _request: body.requestId, _category: body.category, _issue: body.issue ?? null, _subject: body.subject, _description: body.description } : null, displayTicketReference);
const ticketArgs = (_body, params) => uuid(params.id) ? { _ticket: params.id } : null;
export const myTicket = route('my_support_ticket', ticketArgs, ticket => ({ ticket: displayTicketReference(ticket) }));
export const resolveTicket = route('resolve_support_ticket', ticketArgs, () => ({ status: 'resolved' }));
export const adminTicket = route('admin_support_ticket', ticketArgs, ticket => ({ ticket: displayTicketReference(ticket) }));
export const adminSupportProgress = route('my_admin_support_progress', () => ({}));
export const adminSupportCheckIn = route('admin_support_check_in', () => ({}));
export const rateTicketReply = route('rate_support_reply', (body, params) => uuid(params.id) && uuid(params.replyId)
  && Number.isInteger(body.score) && body.score >= 1 && body.score <= 5
  ? { _ticket: params.id, _reply: params.replyId, _score: body.score } : null, () => ({ saved: true }));
export const replyTicket = route('reply_support_ticket', (body, params) => uuid(params.id) && uuid(body.requestId) && text(body.message,2,2000)
  ? { _ticket: params.id, _body: body.message, _request: body.requestId } : null, () => ({ saved: true }));
export const updateTicket = route('update_support_ticket', (body, params) => uuid(params.id) && Number.isSafeInteger(body.version)
  && body.version > 0 && ['investigating','waiting','resolved'].includes(body.status) && text(body.reply || '',0,2000)
  && text(body.outcome || '',0,2000) && [undefined,'','release','refund'].includes(body.settlement)
  ? { _ticket: params.id, _version: body.version, _status: body.status, _reply: body.reply || '', _outcome: body.outcome || '', _settlement: body.settlement || null } : null,
() => ({ saved: true }));
