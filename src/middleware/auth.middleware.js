import { createUserSupabaseClient } from '../config/supabase.js';

export const authorize = async (req, res, next) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader) return res.status(401).json({ message: "Missing authorization header" });

    const [scheme, token, ...extra] = authHeader.split(' ');
    if (scheme !== 'Bearer' || !token || extra.length) {
      return res.status(401).json({ message: 'Invalid authorization header format' });
    }

    const supabase = createUserSupabaseClient(token);
    const { data, error } = await supabase.auth.getUser(token);
    if (error || !data.user) return res.status(401).json({ message: 'Invalid or expired access token' });

    req.supabase = supabase;
    req.userId = data.user.id;

    next();
  } catch (error) {
    if (error.message?.startsWith('Missing required environment variables:')) return next(error);
    return res.status(401).json({ message: "Invalid or expired access token" });
  }
};

export const authorizeRole = (allowedRoles) => async (req, res, next) => {
  try {
    const { data, error } = await req.supabase
      .from('profiles')
      .select('role')
      .eq('id', req.userId)
      .single();
    if (error || !data?.role) return res.status(403).json({ message: 'User role not found' });

    const allowed = Array.isArray(allowedRoles) ? allowedRoles : [allowedRoles];
    if (!allowed.includes(data.role)) {
      return res.status(403).json({ message: 'Forbidden: Insufficient permissions' });
    }

    req.userRole = data.role;
    return next();
  } catch (error) {
    return next(error);
  }
};
