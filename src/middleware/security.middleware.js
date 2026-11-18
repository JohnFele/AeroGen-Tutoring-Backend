export function preventPrivateCaching(req, res, next) {
  if (req.headers.authorization || /^\/api\/v1\/(?:users|workspace|admin)(?:\/|$)/i.test(req.path)) {
    res.set('Cache-Control', 'private, no-store');
    res.set('Pragma', 'no-cache');
    res.vary('Authorization');
  }
  next();
}
