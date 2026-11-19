export const tutorApprovalRelation = 'tutor_profile:tutor_profiles!tutor_profiles_user_id_fkey(is_approved)';

export const isApprovedTutor = profile => !profile.identity_correction_required && profile.role === 'tutor' && profile.tutor_profile?.is_approved === true;
