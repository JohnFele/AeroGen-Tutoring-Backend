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

const profileSelect = `id, first_name, last_name, email, phone, location, role, auth_provider, bio, is_verified, profile_setup_pending, curriculum_codes, study_level_code, study_grade, study_subject_ids, study_institution, study_programme, study_goals, demo_dataset, created_at, updated_at,${tutorApprovalRelation}`;
const profileFieldMap = {
  firstName: 'first_name',
  lastName: 'last_name',
  phone: 'phone',
  location: 'location',
  bio: 'bio',
  studyInstitution: 'study_institution',
  studyProgramme: 'study_programme',
  studyGoals: 'study_goals',
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
  curriculumCodes: profile.curriculum_codes ?? [],
  studyLevelCode: profile.study_level_code,
  studyGrade: profile.study_grade,
  studySubjectIds: profile.study_subject_ids ?? [],
  studyInstitution: profile.study_institution,
  studyProgramme: profile.study_programme,
  studyGoals: profile.study_goals,
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
      const maximumLength = ['bio','studyGoals'].includes(requestField) ? 2000 :
        ['studyInstitution','studyProgramme'].includes(requestField) ? 150 : 160;
      if (value.length > maximumLength) {
        return res.status(400).json({ message: `${requestField} must be ${maximumLength} characters or fewer.` });
      }
      updates[databaseField] = databaseField === 'bio' ? value : value || null;
    }

    if (Object.hasOwn(req.body ?? {}, 'curriculumCodes')) {
      const codes = req.body.curriculumCodes;
      if (!validCurricula(codes)) {
        return res.status(400).json({ message: 'Choose valid curricula from the list.' });
      }
      updates.curriculum_codes = [...new Set(codes)];
    }
    if (Object.hasOwn(req.body ?? {}, 'studyLevelCode')) {
      const level = req.body.studyLevelCode;
      if (level !== null && (!validCurricula([level]) || !level)) return res.status(400).json({ message: 'Choose a valid education phase.' });
      updates.study_level_code = level;
    }
    if (Object.hasOwn(req.body ?? {}, 'studyGrade')) {
      const grade = req.body.studyGrade;
      if (grade !== null && (!Number.isInteger(grade) || grade < 0 || grade > 12)) return res.status(400).json({ message: 'Choose a valid school grade.' });
      updates.study_grade = grade;
    }
    if (Object.hasOwn(req.body ?? {}, 'studySubjectIds')) {
      const ids = req.body.studySubjectIds;
      if (!Array.isArray(ids) || ids.length > 30 || ids.some(id => !Number.isSafeInteger(id) || id < 1)) {
        return res.status(400).json({ message: 'Choose up to 30 subjects from the list.' });
      }
      updates.study_subject_ids = [...new Set(ids)];
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
    if (error?.code === '22023') return res.status(400).json({ message: error.message });
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

export const getTeachingSubjects = async (req, res, next) => {
  try {
    const { data, error } = await req.supabase.from('profiles')
      .select('role,curriculum_codes,teaching_level_codes,tutor_profile:tutor_profiles!tutor_profiles_user_id_fkey(is_approved,updated_at,tutor_subjects(subject_id,curriculum_codes))')
      .eq('id', req.userId).single();
    if (error) return next(error);
    if (!isApprovedTutor(data)) return res.status(403).json({ message: 'Tutor approval required.' });
    res.set('Cache-Control', 'no-store');
    return res.json({ curriculumCodes: data.curriculum_codes, levelCodes: data.teaching_level_codes, subjects: data.tutor_profile.tutor_subjects, updatedAt: data.tutor_profile.updated_at });
  } catch (error) {
    return next(error);
  }
};

const validCurricula = codes => Array.isArray(codes) && codes.length <= 20 && codes.every(code =>
  typeof code === 'string' && code.length <= 60 && /^[a-z0-9]+(-[a-z0-9]+)*$/.test(code));

export const getTutorListing = async (req, res, next) => {
  try {
    const { data, error } = await req.supabase.from('profiles')
      .select('role,tutor_profile:tutor_profiles!tutor_profiles_user_id_fkey(is_approved,updated_at,public_name,bio,city,province,teaching_style,years_experience,teaching_modes,hourly_rate,students_per_session)')
      .eq('id', req.userId).single();
    if (error) return next(error);
    if (!isApprovedTutor(data)) return res.status(403).json({ message: 'Tutor approval required.' });
    res.set('Cache-Control', 'no-store');
    return res.json(data.tutor_profile);
  } catch (error) {
    return next(error);
  }
};

export const saveTutorListing = async (req, res, next) => {
  try {
    const { details, updatedAt } = req.body ?? {};
    if (!details || typeof details !== 'object' || Array.isArray(details) ||
      typeof updatedAt !== 'string' || !Number.isFinite(Date.parse(updatedAt))) {
      return res.status(400).json({ message: 'Enter valid teaching details.' });
    }
    const { data, error } = await req.supabase.rpc('save_my_tutor_listing', {
      _details: details, _expected_updated_at: updatedAt,
    });
    if (error?.code === '22023') return res.status(400).json({ message: error.message });
    if (error?.code === '42501') return res.status(403).json({ message: error.message });
    if (error?.code === 'PT409') return res.status(409).json({ message: error.message });
    if (error) return next(error);
    return res.json({ updatedAt: data });
  } catch (error) {
    return next(error);
  }
};

export const saveTeachingSubjects = async (req, res, next) => {
  try {
    const { curriculumCodes, levelCodes, subjects, updatedAt } = req.body ?? {};
    if (!validCurricula(curriculumCodes) || !Array.isArray(subjects) || subjects.length < 1 || subjects.length > 100 ||
      subjects.some(row => !Number.isSafeInteger(row?.subject_id) || row.subject_id < 1 || !validCurricula(row.curriculum_codes)) ||
      (levelCodes !== undefined && !validCurricula(levelCodes)) || typeof updatedAt !== 'string' || !Number.isFinite(Date.parse(updatedAt))) {
      return res.status(400).json({ message: 'Choose valid curricula and between 1 and 100 teaching subjects.' });
    }
    const { data, error } = await req.supabase.rpc('save_my_teaching_subjects', {
      _curricula: curriculumCodes,
      ...(levelCodes !== undefined ? { _levels: levelCodes } : {}),
      _subjects: subjects.map(({ subject_id, curriculum_codes }) => ({ subject_id, curriculum_codes })),
      _expected_updated_at: updatedAt,
    });
    if (error?.code === '22023') return res.status(400).json({ message: error.message });
    if (error?.code === '42501') return res.status(403).json({ message: error.message });
    if (error?.code === 'PT409') return res.status(409).json({ message: error.message });
    if (error) return next(error);
    return res.json({ updatedAt: data });
  } catch (error) {
    return next(error);
  }
};

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
