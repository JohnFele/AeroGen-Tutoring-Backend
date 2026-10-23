-- Seed the subjects shown by the frontend catalog and tutor application form.
insert into public.subjects (name, category, slug) values
  ('Mathematics', 'Mathematics & Sciences', 'mathematics'),
  ('Advanced Mathematics', 'Mathematics & Sciences', 'advanced-mathematics'),
  ('Physics', 'Mathematics & Sciences', 'physics'),
  ('Chemistry', 'Mathematics & Sciences', 'chemistry'),
  ('Biology', 'Mathematics & Sciences', 'biology'),
  ('Life Sciences', 'Mathematics & Sciences', 'life-sciences'),
  ('Physical Sciences', 'Mathematics & Sciences', 'physical-sciences'),
  ('Statistics', 'Mathematics & Sciences', 'statistics'),
  ('Accounting', 'Mathematics & Sciences', 'accounting'),
  ('English Home Language', 'Languages & Humanities', 'english-home-language'),
  ('English First Additional', 'Languages & Humanities', 'english-first-additional'),
  ('Afrikaans', 'Languages & Humanities', 'afrikaans'),
  ('isiZulu', 'Languages & Humanities', 'isizulu'),
  ('History', 'Languages & Humanities', 'history'),
  ('Geography', 'Languages & Humanities', 'geography'),
  ('Life Orientation', 'Languages & Humanities', 'life-orientation'),
  ('Business Studies', 'Languages & Humanities', 'business-studies'),
  ('Economics', 'Languages & Humanities', 'economics'),
  ('Computer Science', 'Technology & Coding', 'computer-science'),
  ('Python Programming', 'Technology & Coding', 'python-programming'),
  ('Programming', 'Technology & Coding', 'programming'),
  ('Web Development', 'Technology & Coding', 'web-development'),
  ('JavaScript', 'Technology & Coding', 'javascript'),
  ('Java Programming', 'Technology & Coding', 'java-programming'),
  ('C++ Programming', 'Technology & Coding', 'cpp-programming'),
  ('Data Science', 'Technology & Coding', 'data-science'),
  ('App Development', 'Technology & Coding', 'app-development'),
  ('Game Development', 'Technology & Coding', 'game-development'),
  ('Music Theory', 'Creative Arts & Music', 'music-theory'),
  ('Music', 'Creative Arts & Music', 'music'),
  ('Piano', 'Creative Arts & Music', 'piano'),
  ('Guitar', 'Creative Arts & Music', 'guitar'),
  ('Violin', 'Creative Arts & Music', 'violin'),
  ('Visual Arts', 'Creative Arts & Music', 'visual-arts'),
  ('Art', 'Creative Arts & Music', 'art'),
  ('Drama', 'Creative Arts & Music', 'drama'),
  ('Creative Writing', 'Creative Arts & Music', 'creative-writing'),
  ('Graphic Design', 'Creative Arts & Music', 'graphic-design'),
  ('Matric Final Exams', 'Test Preparation', 'matric-final-exams'),
  ('Grade 8-11 Exams', 'Test Preparation', 'grade-8-11-exams'),
  ('University Entrance', 'Test Preparation', 'university-entrance'),
  ('SAT Preparation', 'Test Preparation', 'sat-preparation'),
  ('IELTS Preparation', 'Test Preparation', 'ielts-preparation'),
  ('Career Guidance', 'Test Preparation', 'career-guidance'),
  ('Study Skills', 'Test Preparation', 'study-skills'),
  ('Engineering Mathematics', 'Specialized & University', 'engineering-mathematics'),
  ('Medical Sciences', 'Specialized & University', 'medical-sciences'),
  ('Law Studies', 'Specialized & University', 'law-studies'),
  ('Psychology', 'Specialized & University', 'psychology'),
  ('Marketing', 'Specialized & University', 'marketing'),
  ('Finance', 'Specialized & University', 'finance'),
  ('University Mathematics', 'Specialized & University', 'university-mathematics'),
  ('Research Methodology', 'Specialized & University', 'research-methodology')
on conflict (name) do update set category = excluded.category, slug = excluded.slug, is_active = true;

-- Cover foreign-key lookups and parent-row delete/update checks.
create index if not exists bookings_subject_idx on public.bookings (subject_id);
create index if not exists conversations_booking_idx on public.conversations (booking_id);
create index if not exists conversations_created_by_idx on public.conversations (created_by);
create index if not exists messages_sender_idx on public.messages (sender_id);
create index if not exists reviews_student_idx on public.reviews (student_id);
create index if not exists tutor_application_subjects_subject_idx on public.tutor_application_subjects (subject_id);
create index if not exists tutor_applications_reviewer_idx on public.tutor_applications (reviewer_id);

-- Trigger functions are invoked by database triggers, never through the Data API.
revoke all on function public.handle_new_auth_user() from public, anon, authenticated;
revoke all on function public.handle_auth_user_update() from public, anon, authenticated;
revoke all on function public.rls_auto_enable() from public, anon, authenticated;
