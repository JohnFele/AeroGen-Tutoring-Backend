import { createUserSupabaseClient } from '../config/supabase.js';
import { isApprovedTutor, tutorApprovalRelation } from '../utils/tutorAccess.js';

export const createAuthorize = (getClient = createUserSupabaseClient) => async (req, res, next) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader) return res.status(401).json({ message: "Missing authorization header" });

    const [scheme, token, ...extra] = authHeader.split(' ');
    if (scheme !== 'Bearer' || !token || extra.length) {
      return res.status(401).json({ message: 'Invalid authorization header format' });
    }

    const supabase = getClient(token);
    const { data, error } = await supabase.auth.getUser(token);
    if (error || !data.user) return res.status(401).json({ message: 'Invalid or expired access token' });

    req.supabase = supabase;
    req.userId = data.user.id;
    // getUser above has verified this exact token with Supabase Auth.
    const claims = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString());
    req.authAssurance = claims.aal === 'aal2' ? 'aal2' : 'aal1';
    const { data: security, error: securityError } = await supabase.rpc('my_session_security').abortSignal(AbortSignal.timeout(10000));
    if (securityError) return next(securityError);
    if (!security?.valid) return res.status(401).json({ code: 'SESSION_EXPIRED', message: 'Your session has expired. Sign in again to continue.' });
    req.sessionSecurity = security;
    req.adminMfaVerified = security.admin_verified === true;

    next();
  } catch (error) {
    if (error.message?.startsWith('Missing required environment variables:')) return next(error);
    return res.status(401).json({ message: "Invalid or expired access token" });
  }
};

export const authorize = createAuthorize();

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

    if (['admin', 'superUser'].includes(data.role) && (req.authAssurance !== 'aal2' || !req.adminMfaVerified)) {
      return res.status(403).json({ code: 'ADMIN_MFA_REQUIRED', message: 'Verify your authenticator code to access administrator features.' });
    }

    req.userRole = data.role;
    return next();
  } catch (error) {
    return next(error);
  }
};

export const requireTutorApproval = async (req, res, next) => {
  try {
    const { data, error } = await req.supabase.from('profiles')
      .select(`role,identity_correction_required,${tutorApprovalRelation}`).eq('id', req.userId).maybeSingle();
    if (error) return next(error);
    if (!data) return res.status(403).json({ message: 'User profile not found.' });
    if(data.identity_correction_required)return res.status(403).json({code:'TUTOR_IDENTITY_CORRECTION_REQUIRED',message:'Correct your tutor identity information before accessing your dashboard.'});
    if (data.role === 'tutor' && !isApprovedTutor(data)) {
      return res.status(403).json({
        code: 'TUTOR_APPROVAL_REQUIRED',
        message: 'Complete your tutor application and wait for approval to access the tutor dashboard.',
      });
    }
    return next();
  } catch (error) {
    return next(error);
  }
};
