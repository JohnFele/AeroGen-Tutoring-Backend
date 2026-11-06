const screenshotLimit = 2 * 1024 * 1024;
const maxBase64Length = 4 * Math.ceil(screenshotLimit / 3);

export function screenshotArgs(value) {
  if (value === undefined || value === null) return { _mime: null, _base64: null };
  if (typeof value !== 'string' || value.length > maxBase64Length + 32) return null;
  const match = /^data:(image\/(?:png|jpeg|webp));base64,([A-Za-z0-9+/]+={0,2})$/.exec(value);
  if (!match || match[2].length > maxBase64Length || match[2].length % 4 !== 0) return null;
  const [, mime, base64] = match;
  const bytes = Buffer.from(base64, 'base64');
  if (bytes.length < 12 || bytes.length > screenshotLimit) return null;
  const valid = mime === 'image/png' ? bytes.subarray(0, 8).toString('hex') === '89504e470d0a1a0a'
    : mime === 'image/jpeg' ? bytes.subarray(0, 3).toString('hex') === 'ffd8ff'
      : bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WEBP';
  return valid ? { _mime: mime, _base64: base64 } : null;
}

export function triageArgs(body, version) {
  if (!Number.isSafeInteger(version) || version < 1 || version > 2147483647
    || !['category', 'handoff', 'stage'].includes(body?.action)
    || (body.value !== undefined && (typeof body.value !== 'string' || body.value.length > 30))
    || (body.notes !== undefined && (typeof body.notes !== 'string' || body.notes.length > 2000))) return null;
  return { _version: version, _action: body.action, _value: body.value || null, _notes: body.notes || null };
}

export function downloadBugScreenshot(guest) {
  return async (req, res, next) => {
    if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(req.params.id)) {
      return res.status(400).json({ message: 'Invalid report reference.' });
    }
    try {
      const { data, error } = await req.supabase.rpc('support_bug_screenshot', {
        _id: req.params.id, _guest: guest, _metadata: false,
      }).abortSignal(AbortSignal.timeout(15000));
      if (error && error.code !== 'PT404') throw error;
      if (!data || error) return res.status(404).json({ message: 'Screenshot not found.' });
      res.set('Cache-Control', 'private, no-store');
      res.set('X-Content-Type-Options', 'nosniff');
      res.set('Content-Disposition', `attachment; filename="bug-screenshot.${data.mime.split('/')[1]}"`);
      return res.type(data.mime).send(Buffer.from(data.base64, 'base64'));
    } catch (error) { return next(error); }
  };
}
