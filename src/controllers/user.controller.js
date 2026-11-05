import { isApprovedTutor, tutorApprovalRelation } from '../utils/tutorAccess.js';

export const me = async (req, res, next) => {
  try {
    if (!req.userId) return res.status(401).json({ message: "Unauthorized" });

    const { data: profile, error } = await req.supabase
      .from('profiles')
      .select(profileSelect)
      .eq('id', req.userId)
      .single();
    if (error?.code === 'PGRST116') return res.status(404).json({ message: 'User profile not found' });
    if (error) return next(error);

    res.set('Cache-Control', 'no-store');
    return res.status(200).json({
      message: "User profile fetched successfully.",
      user: serializeProfile(profile),
    });
  } catch (error) {
    next(error);
  }
};

const profileSelect = `id, first_name, last_name, email, phone, location, role, auth_provider, bio, is_verified, profile_setup_pending, demo_dataset, created_at, updated_at,${tutorApprovalRelation}`;
const profileFieldMap = {
  firstName: 'first_name',
  lastName: 'last_name',
  phone: 'phone',
  location: 'location',
  bio: 'bio',
};

const serializeProfile = (profile) => ({
  id: profile.id,
  firstName: profile.first_name,
  lastName: profile.last_name,
  email: profile.email,
  phone: profile.phone,
  location: profile.location,
  role: profile.role,
  tutorApproved: isApprovedTutor(profile),
  authProvider: profile.auth_provider,
  bio: profile.bio,
  isVerified: profile.is_verified,
  profileSetupPending: profile.profile_setup_pending,
  isDemo: Boolean(profile.demo_dataset),
  demoDataset: profile.demo_dataset,
  createdAt: profile.created_at,
  updatedAt: profile.updated_at,
});

export const updateMe = async (req, res, next) => {
  try {
    const updates = {};
    for (const [requestField, databaseField] of Object.entries(profileFieldMap)) {
      if (!Object.hasOwn(req.body ?? {}, requestField)) continue;
      if (typeof req.body[requestField] !== 'string') {
        return res.status(400).json({ message: `${requestField} must be a string.` });
      }
      const value = req.body[requestField].trim();
      const maximumLength = requestField === 'bio' ? 2000 : 160;
      if (value.length > maximumLength) {
        return res.status(400).json({ message: `${requestField} must be ${maximumLength} characters or fewer.` });
      }
      updates[databaseField] = databaseField === 'bio' ? value : value || null;
    }

    if (!Object.keys(updates).length) {
      return res.status(400).json({ message: 'Provide at least one profile field to update.' });
    }
    if ('first_name' in updates && !updates.first_name) {
      return res.status(400).json({ message: 'First name is required.' });
    }
    if ('last_name' in updates && !updates.last_name) {
      return res.status(400).json({ message: 'Last name is required.' });
    }

    if (req.body?.completeSetup === true) {
      if (!updates.first_name || !updates.last_name || !updates.location || !/^\+[1-9]\d{8,14}$/.test(updates.phone || '')) {
        return res.status(400).json({ message: 'Enter your name, a valid phone number and your location to complete setup.' });
      }
      updates.profile_setup_pending = false;
    }

    const { data: profile, error } = await req.supabase
      .from('profiles')
      .update(updates)
      .eq('id', req.userId)
      .select(profileSelect)
      .single();
    if (error?.code === 'PGRST116') return res.status(404).json({ message: 'User profile not found.' });
    if (error?.code === '22023' && updates.profile_setup_pending === false) return res.status(400).json({ message: error.message });
    if (error) return next(error);

    return res.status(200).json({ message: 'Profile updated successfully.', user: serializeProfile(profile) });
  } catch (error) {
    return next(error);
  }
};

const preferenceFields = [
  'email_messages', 'email_booking_updates', 'email_payment_updates',
  'push_messages', 'push_booking_updates', 'push_payment_updates',
];

const defaultPreferences = Object.fromEntries(preferenceFields.map((field) => [field, true]));

export const getNotificationPreferences = async (req, res, next) => {
  try {
    const { data, error } = await req.supabase
      .from('user_notification_preferences')
      .select(preferenceFields.join(','))
      .eq('user_id', req.userId)
      .maybeSingle();
    if (error) return next(error);
    return res.status(200).json({ preferences: data ?? defaultPreferences });
  } catch (error) {
    return next(error);
  }
};

export const updateNotificationPreferences = async (req, res, next) => {
  try {
    const preferences = {};
    for (const field of preferenceFields) {
      if (!Object.hasOwn(req.body ?? {}, field)) continue;
      if (typeof req.body[field] !== 'boolean') {
        return res.status(400).json({ message: `${field} must be true or false.` });
      }
      preferences[field] = req.body[field];
    }
    if (!Object.keys(preferences).length) {
      return res.status(400).json({ message: 'Provide at least one notification preference.' });
    }

    const { data, error } = await req.supabase
      .from('user_notification_preferences')
      .upsert({ user_id: req.userId, ...preferences }, { onConflict: 'user_id' })
      .select(preferenceFields.join(','))
      .single();
    if (error) return next(error);
    return res.status(200).json({ message: 'Notification preferences saved.', preferences: data });
  } catch (error) {
    return next(error);
  }
};
