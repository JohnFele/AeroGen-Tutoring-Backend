export const demoDatasetName = 'aerogen-live-demo-v1'
const accountId = number => `de000000-0000-4000-8000-${String(number).padStart(12, '0')}`
export const demoAccounts = [
  { key: 'student-primary', id: accountId(101), email: 'demo.student.primary@example.test', firstName: 'Demo Primary', lastName: 'Student', role: 'student', location: 'Cape Town', scenario: 'Grade 5; maths and language lessons', level: 'intermediate' },
  { key: 'student-school', id: accountId(102), email: 'demo.student.school@example.test', firstName: 'Demo High School', lastName: 'Student', role: 'student', location: 'Durban', scenario: 'Grade 11; science, cancelled and upcoming sessions', level: 'fet' },
  { key: 'student-university', id: accountId(103), email: 'demo.student.university@example.test', firstName: 'Demo University', lastName: 'Student', role: 'student', location: 'Johannesburg', scenario: 'Second-year engineering; university module support', level: 'undergraduate' },
  { key: 'student-college', id: accountId(104), email: 'demo.student.college@example.test', firstName: 'Demo College', lastName: 'Student', role: 'student', location: 'Pretoria', scenario: 'College accounting; completed and upcoming sessions', level: 'college' },
  { key: 'student-postgraduate', id: accountId(105), email: 'demo.student.postgraduate@example.test', firstName: 'Demo Postgraduate', lastName: 'Student', role: 'student', location: 'Johannesburg', scenario: 'Research/statistics; declined booking', level: 'postgraduate' },
  { key: 'student-new', id: accountId(106), email: 'demo.student.new@example.test', firstName: 'Demo New', lastName: 'Student', role: 'student', location: 'Cape Town', scenario: 'Empty state: no bookings, messages or notifications', level: 'fet' },
  { key: 'tutor-maths', id: accountId(201), email: 'demo.tutor.maths@example.test', firstName: 'Demo Maths', lastName: 'Tutor', role: 'tutor', location: 'Cape Town', province: 'Western Cape', scenario: 'Approved maths/accounting tutor; mixed booking states', subjects: ['Mathematics', 'Statistics', 'Engineering Mathematics', 'Accounting', 'Research Methodology'], rate: 200, approved: true, qualification: 'Demonstration qualification: BSc Applied Mathematics', years: 6 },
  { key: 'tutor-science', id: accountId(202), email: 'demo.tutor.science@example.test', firstName: 'Demo Science', lastName: 'Tutor', role: 'tutor', location: 'Durban', province: 'KwaZulu-Natal', scenario: 'Approved science tutor; in-person and online sessions', subjects: ['Physics', 'Chemistry', 'Life Sciences', 'Physical Sciences'], rate: 220, approved: true, qualification: 'Demonstration qualification: MSc Physical Sciences', years: 5 },
  { key: 'tutor-languages', id: accountId(203), email: 'demo.tutor.languages@example.test', firstName: 'Demo Languages', lastName: 'Tutor', role: 'tutor', location: 'Johannesburg', province: 'Gauteng', scenario: 'Approved language tutor; primary and university English', subjects: ['English Home Language', 'English First Additional', 'isiZulu Home Language', 'Academic English'], rate: 180, approved: true, qualification: 'Demonstration qualification: BA Languages', years: 4 },
  { key: 'tutor-engineering', id: accountId(204), email: 'demo.tutor.engineering@example.test', firstName: 'Demo Engineering', lastName: 'Tutor', role: 'tutor', location: 'Johannesburg', province: 'Gauteng', scenario: 'Approved university tutor; engineering and module requests', subjects: ['Fluid Mechanics', 'Thermodynamics', 'Engineering Mathematics', 'Structural Analysis'], rate: 300, approved: true, qualification: 'Demonstration qualification: MEng Mechanical Engineering', years: 8 },
  { key: 'tutor-pending', id: accountId(205), email: 'demo.tutor.pending@example.test', firstName: 'Demo Pending', lastName: 'Tutor', role: 'tutor', location: 'Pretoria', province: 'Gauteng', scenario: 'Submitted application; unapproved and hidden from discovery', subjects: ['Computer Science', 'Python Programming'], rate: 240, approved: false, qualification: 'Demonstration qualification: BSc Computer Science', years: 1 },
]

export const demoBookingCases = [
  ['primary-maths-completed', 'student-primary', 'tutor-maths', 'Mathematics', -14, 15, 60, 'completed', 'paid', 'online'],
  ['primary-language-completed', 'student-primary', 'tutor-languages', 'English Home Language', -11, 15, 60, 'completed', 'paid', 'online'],
  ['school-science-completed', 'student-school', 'tutor-science', 'Physical Sciences', -7, 16, 90, 'completed', 'paid', 'in-person'],
  ['university-engineering-completed', 'student-university', 'tutor-engineering', 'Fluid Mechanics', -5, 18, 60, 'completed', 'paid', 'online'],
  ['college-accounting-completed', 'student-college', 'tutor-maths', 'Accounting', -4, 14, 60, 'completed', 'paid', 'online'],
  ['primary-maths-upcoming', 'student-primary', 'tutor-maths', 'Mathematics', 1, 16, 60, 'confirmed', 'authorized', 'online'],
  ['school-science-upcoming', 'student-school', 'tutor-science', 'Physical Sciences', 2, 17, 60, 'confirmed', 'paid', 'in-person'],
  ['university-engineering-upcoming', 'student-university', 'tutor-engineering', 'Thermodynamics', 3, 18, 90, 'confirmed', 'pending', 'online'],
  ['college-accounting-upcoming', 'student-college', 'tutor-maths', 'Accounting', 4, 14, 60, 'confirmed', 'pending', 'online'],
  ['university-engineering-pending', 'student-university', 'tutor-engineering', 'Fluid Mechanics', 5, 16, 60, 'pending', 'pending', 'online'],
  ['school-maths-cancelled', 'student-school', 'tutor-maths', 'Mathematics', -2, 16, 60, 'cancelled', 'refunded', 'online'],
  ['postgraduate-statistics-declined', 'student-postgraduate', 'tutor-maths', 'Statistics', 6, 17, 60, 'declined', 'failed', 'online'],
].map(([key, student, tutor, subject, dayOffset, hour, duration, status, paymentStatus, mode]) => ({ key, student, tutor, subject, dayOffset, hour, duration, status, paymentStatus, mode }))
