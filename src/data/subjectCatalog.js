// Canonical, extensible subject catalogue. Entries describe tutoring areas, not
// accreditation, a particular institution's modules, or confirmed tutor supply.
export const educationLevels = [
  { code: 'foundation', name: 'Foundation · Grades R–3', min_grade: 0, max_grade: 3 },
  { code: 'intermediate', name: 'Intermediate · Grades 4–6', min_grade: 4, max_grade: 6 },
  { code: 'senior', name: 'Senior · Grades 7–9', min_grade: 7, max_grade: 9 },
  { code: 'fet', name: 'High school · Grades 10–12', min_grade: 10, max_grade: 12 },
  { code: 'college', name: 'College / TVET', min_grade: null, max_grade: null },
  { code: 'undergraduate', name: 'University · Undergraduate', min_grade: null, max_grade: null },
  { code: 'postgraduate', name: 'University · Postgraduate', min_grade: null, max_grade: null },
  { code: 'adult', name: 'Adult & continuing learning', min_grade: null, max_grade: null },
].map((level, index) => ({ ...level, sort_order: index }))

export const subjectCategories = [
  ['primary-foundations', 'Primary Foundations', '🌱'],
  ['mathematics', 'Mathematics', '📐'],
  ['natural-sciences', 'Natural Sciences', '🔬'],
  ['languages', 'Languages', '📚'],
  ['humanities-social-sciences', 'Humanities & Social Sciences', '🌍'],
  ['technology-coding', 'Technology & Coding', '💻'],
  ['business-economics', 'Business & Economics', '📊'],
  ['engineering-built-environment', 'Engineering & Built Environment', '⚙️'],
  ['health-medical-sciences', 'Health & Medical Sciences', '🧬'],
  ['law-public-administration', 'Law & Public Administration', '⚖️'],
  ['education-teaching', 'Education & Teaching', '🎓'],
  ['agriculture-environment', 'Agriculture & Environmental Studies', '🌿'],
  ['creative-arts-music', 'Creative Arts & Music', '🎨'],
  ['vocational-technical', 'Vocational & Technical Studies', '🛠️'],
  ['test-preparation', 'Study Skills & Test Preparation', '🎯'],
  ['research-academic-skills', 'Research & Academic Skills', '🔍'],
].map(([slug, name, emoji], index) => ({ slug, name, emoji, sort_order: index }))

const school = ['foundation', 'intermediate', 'senior', 'fet']
const secondary = ['senior', 'fet']
const tertiary = ['college', 'undergraduate', 'postgraduate']
const advanced = ['undergraduate', 'postgraduate']
const all = educationLevels.map(level => level.code)
const entries = []
// Line format: name | comma-separated search aliases. Levels are explicit per group.
function group(category, levels, lines) {
  for (const line of lines.trim().split('\n')) {
    const [name, aliases = ''] = line.trim().split('|').map(value => value.trim())
    entries.push({ name, category, levels: [...levels], aliases: aliases.split(',').map(value => value.trim()).filter(Boolean) })
  }
}

group('primary-foundations', ['foundation', 'intermediate'], `
Reading & Literacy | reading comprehension, early literacy
Phonics | phonemic awareness, letter sounds
Handwriting | fine motor writing
Spelling & Vocabulary | spelling, vocabulary
Numeracy | number sense, counting
Life Skills | personal social wellbeing
Homework Support | homework help
`)
group('primary-foundations', ['foundation'], `
School Readiness | Grade R, early childhood, reception
Beginning Reading | emergent reading
Basic Number Operations | addition, subtraction
`)
group('primary-foundations', ['intermediate', 'senior'], `
Natural Sciences & Technology | NST
Social Sciences | history and geography
`)
group('mathematics', [...school, ...tertiary, 'adult'], `
Mathematics | maths, math
`)
group('mathematics', ['fet', 'college', 'adult'], `
Mathematical Literacy | maths literacy, math lit
Technical Mathematics | technical maths
`)
group('mathematics', ['intermediate', 'senior', 'fet', 'college'], `
Arithmetic | basic maths
Fractions, Decimals & Percentages | fractions, decimals, percentages
Algebra | equations, inequalities
Geometry | Euclidean geometry
Measurement | perimeter, area, volume
`)
group('mathematics', [...secondary, 'college', 'undergraduate'], `
Trigonometry | trig
Functions & Graphs | functions, graphs
Probability | chance
`)
group('mathematics', ['fet', ...advanced], `
Advanced Mathematics | AP maths, further mathematics, additional mathematics
Calculus | differentiation, integration
Statistics | statistical methods
`)
group('mathematics', tertiary, `
Engineering Mathematics
Business Mathematics
Financial Mathematics | financial maths
Discrete Mathematics
Numerical Methods
`)
group('mathematics', advanced, `
University Mathematics
Linear Algebra | matrices, vectors
Multivariable Calculus | calculus 3
Differential Equations | ODE, PDE
Real Analysis
Complex Analysis
Abstract Algebra
Number Theory
Topology
Mathematical Logic
Optimization | optimisation, operations research
Stochastic Processes
Actuarial Mathematics | actuarial science
`)
group('natural-sciences', ['intermediate', ...secondary], `
Natural Sciences | NS
`)
group('natural-sciences', ['fet', 'college'], `
Physical Sciences | physical science
Life Sciences | life science
Technical Sciences
`)
group('natural-sciences', ['fet', ...tertiary], `
Physics
Chemistry
Biology
`)
group('natural-sciences', advanced, `
Applied Physics
Classical Mechanics
Electromagnetism
Waves & Optics
Thermal Physics
Quantum Mechanics
Nuclear Physics
Astronomy & Astrophysics
Organic Chemistry
Inorganic Chemistry
Physical Chemistry
Analytical Chemistry
Biochemistry
Microbiology
Genetics
Molecular Biology
Cell Biology
Botany
Zoology
Biotechnology
Geology | earth science
Geophysics
`)

// School-language streams are separate subjects; aliases retain older catalogue names.
const localLanguages = ['English', 'Afrikaans', 'isiZulu', 'isiXhosa', 'Sesotho', 'Setswana', 'Sepedi', 'Siswati', 'Tshivenda', 'Xitsonga', 'isiNdebele', 'South African Sign Language']
for (const language of localLanguages) {
  const extraAliases = language === 'Sepedi' ? ['Northern Sotho', 'Sesotho sa Leboa'] : language === 'Siswati' ? ['siSwati'] : language === 'South African Sign Language' ? ['SASL'] : []
  for (const stream of ['Home Language', 'First Additional Language', 'Second Additional Language']) {
    const levels = language === 'South African Sign Language' && stream !== 'Home Language' ? ['adult'] : stream === 'Second Additional Language' ? ['senior', 'fet', 'adult'] : [...school, 'adult']
    // SASL is provided as a home-language subject and as general adult learning.
    if (language === 'South African Sign Language' && stream !== 'Home Language') continue
    const name = language === 'English' && stream === 'First Additional Language' ? 'English First Additional' : `${language} ${stream}`
    entries.push({ name, category: 'languages', levels, aliases: [...extraAliases, `${language} ${stream === 'Home Language' ? 'HL' : stream === 'First Additional Language' ? 'FAL' : 'SAL'}`, ...(name === 'English First Additional' ? ['English First Additional Language'] : [])] })
  }
  entries.push({ name: language, category: 'languages', levels: ['college', ...advanced, 'adult'], aliases: extraAliases })
}
group('languages', ['senior', 'fet', ...tertiary, 'adult'], `
French
German
Spanish
Portuguese
Mandarin Chinese | Chinese, Mandarin
Arabic
Italian
Latin
Greek
Hindi
Tamil
Urdu
Hebrew
Japanese
Korean
Dutch
Swahili | Kiswahili
Russian
`)
group('languages', [...tertiary, 'adult'], `
Academic English | English for academic purposes, EAP
English as a Foreign Language | EFL, ESL, TEFL
Business English
Translation & Interpreting
Linguistics
Literature | literary studies
English Literature
African Literature
`)
group('humanities-social-sciences', ['intermediate', ...secondary, ...tertiary], `
History
Geography
`)
group('humanities-social-sciences', secondary, `
Life Orientation | LO
Religion Studies
`)
group('humanities-social-sciences', advanced, `
Psychology
Sociology
Anthropology
Philosophy
Political Science | politics
International Relations
Development Studies
Social Work
Criminology
Archaeology
African Studies
Gender Studies
Theology
Religious Studies
Human Geography
Physical Geography
Media & Communication Studies | communication science
Journalism
Library & Information Science
Public Policy
`)
group('technology-coding', ['senior', 'fet', 'college', 'adult'], `
Computer Applications Technology | CAT
Information Technology | IT
Digital Literacy | computer literacy, computer basics
Office Applications | Microsoft Office, Word, Excel, PowerPoint
`)
group('technology-coding', ['foundation', 'intermediate', 'senior'], `
Coding & Robotics | coding and robotics, Scratch, block coding
`)
group('technology-coding', ['fet', ...tertiary, 'adult'], `
Computer Science | computing, CS
Programming | coding
Python Programming | Python
Web Development | HTML, CSS
JavaScript | JS
Java Programming | Java
C++ Programming | C++
C Programming
C# Programming | C sharp
App Development | mobile development
Game Development
Databases & SQL | databases, SQL, PostgreSQL
Computer Networks | networking
Cybersecurity | information security
`)
group('technology-coding', tertiary, `
Data Structures & Algorithms | DSA, algorithms
Software Engineering
Operating Systems
Computer Architecture
Information Systems
Systems Analysis & Design
Cloud Computing
Human-Computer Interaction | HCI, UX
Data Science
Artificial Intelligence | AI
Machine Learning | ML
Deep Learning
Computer Graphics
Distributed Systems
Internet of Things | IoT
Robotics
Business Intelligence | BI
Data Analytics
`)
group('business-economics', ['senior'], `
Economic & Management Sciences | EMS, economic management sciences
`)
group('business-economics', ['fet', ...tertiary, 'adult'], `
Accounting
Business Studies
Economics
Entrepreneurship
`)
group('business-economics', tertiary, `
Financial Accounting
Management Accounting
Cost Accounting
Auditing
Taxation | tax
Finance
Corporate Finance
Investments
Financial Management
Microeconomics
Macroeconomics
Econometrics
Business Management
Marketing
Human Resource Management | HR, HRM
Organisational Behaviour | organizational behaviour
Operations Management
Supply Chain Management
Logistics
Project Management
Risk Management
Insurance
International Business
Business Strategy
Business Ethics
Public Finance
Tourism Management
Hospitality Management
`)
group('engineering-built-environment', ['senior'], `
Technology
`)
group('engineering-built-environment', ['fet', 'college'], `
Engineering Graphics & Design | EGD, engineering graphics and design
Civil Technology
Electrical Technology
Mechanical Technology
`)
group('engineering-built-environment', tertiary, `
Engineering Drawing | technical drawing
Computer-Aided Design | CAD
Engineering Mechanics
Statics
Dynamics
Strength of Materials | mechanics of materials
Fluid Mechanics
Thermodynamics
Heat Transfer
Materials Science
Circuit Analysis | electrical circuits
Electronics
Digital Systems
Control Systems
Signals & Systems
Power Systems
Civil Engineering
Structural Analysis
Geotechnical Engineering
Transportation Engineering
Water Engineering
Mechanical Engineering
Electrical Engineering
Chemical Engineering
Industrial Engineering
Mechatronics
Mining Engineering
Metallurgical Engineering
Aeronautical Engineering
Architecture
Architectural Design
Construction Management
Quantity Surveying
Land Surveying
Urban & Regional Planning
Property Studies
`)
group('health-medical-sciences', advanced, `
Medical Sciences
Human Anatomy | anatomy
Human Physiology | physiology
Pathophysiology
Pharmacology
Pathology
Immunology
Medical Biochemistry
Clinical Skills
Medicine
Nursing
Pharmacy
Dentistry
Physiotherapy
Occupational Therapy
Speech-Language Therapy
Audiology
Optometry
Radiography
Nutrition & Dietetics
Public Health
Epidemiology
Biostatistics
Medical Ethics
Veterinary Science
Sports & Exercise Science | sports science
`)
group('law-public-administration', tertiary, `
Law Studies | law, legal studies
Introduction to Law
Constitutional Law
Administrative Law
Criminal Law
Criminal Procedure
Law of Contract
Law of Delict | tort law
Property Law
Family Law
Labour Law | employment law
Company Law | corporate law
Commercial Law
Law of Evidence
Civil Procedure
International Law
Human Rights Law
Intellectual Property Law
Environmental Law
Legal Research & Writing
Public Administration
Public Management
Governance
`)
group('education-teaching', tertiary, `
Education Studies
Educational Psychology
Curriculum Studies
Teaching Methodology | pedagogy, didactics
Foundation Phase Teaching
Intermediate Phase Teaching
Senior Phase Teaching
FET Teaching
Early Childhood Development | ECD
Inclusive Education
Classroom Management
Assessment & Evaluation
Educational Technology
Mathematics Education
Science Education
Language Education
Adult Education
`)
group('agriculture-environment', ['fet', 'college'], `
Agricultural Sciences | agricultural science
Agricultural Management Practices
Agricultural Technology
`)
group('agriculture-environment', tertiary, `
Agronomy
Soil Science
Animal Science
Horticulture
Plant Pathology
Agricultural Economics
Agricultural Engineering
Food Science
Forestry
Ecology
Environmental Science
Environmental Management
Conservation Biology
Marine Science
Oceanography
Climate Science
Hydrology
Geographic Information Systems | GIS
Remote Sensing
Sustainability
`)
group('creative-arts-music', ['intermediate', 'senior'], `
Creative Arts
`)
group('creative-arts-music', [...secondary, ...tertiary, 'adult'], `
Music
Music Theory
Visual Arts
Art
Drama | dramatic arts
Dance Studies
Design
Creative Writing
Graphic Design
Photography
Film Studies
Animation
Fashion Design
Interior Design
`)
group('creative-arts-music', all, `
Piano
Guitar
Violin
Singing & Voice | vocal coaching
Drums & Percussion
`)
group('creative-arts-music', tertiary, `
Music Production
Sound Engineering
Composition
Art History
`)
group('vocational-technical', ['fet', 'college', 'adult'], `
Consumer Studies
Hospitality Studies
Tourism
Engineering Science
Electrotechnics
Industrial Electronics
Fitting & Machining
Welding
Plumbing
Carpentry & Joinery
Automotive Technology
Electrical Trade Theory
Mechanical Draughting
Building & Structural Construction
Office Administration
Business Practice
Contact Centre Operations
Safety in Society
Educare
`)
group('test-preparation', ['fet', 'adult'], `
Matric Final Exams | NSC, matric revision
Matric Rewrite | matric upgrade
National Benchmark Tests | NBT, AQL, quantitative literacy
University Entrance
SAT Preparation | SAT
ACT Preparation | ACT
`)
group('test-preparation', ['senior', 'fet'], `
Grade 8-11 Exams
Cambridge IGCSE Preparation | IGCSE
Cambridge AS & A Level Preparation | A levels, AS levels
International Baccalaureate Preparation | IB diploma
`)
group('test-preparation', ['college', 'undergraduate', 'postgraduate', 'adult'], `
IELTS Preparation | IELTS
TOEFL Preparation | TOEFL
GRE Preparation | GRE
GMAT Preparation | GMAT
`)
group('test-preparation', all, `
Study Skills | study techniques
Exam Techniques | exam preparation
Time Management
`)
group('test-preparation', ['senior', 'fet', 'college', 'undergraduate', 'adult'], `
Career Guidance
`)
group('research-academic-skills', advanced, `
Research Methodology | research methods
Quantitative Research
Qualitative Research
Mixed Methods Research
Academic Writing
Essay Writing
Literature Reviews
Research Proposal Writing
Dissertation & Thesis Support | thesis, dissertation
Statistical Data Analysis | SPSS, R, Stata
Scientific Writing
Referencing & Citation | APA, Harvard, citations
Presentation Skills
Critical Thinking
`)

const popularNames = new Set(['Reading & Literacy', 'Phonics', 'Numeracy', 'Life Skills', 'Mathematics', 'Mathematical Literacy', 'Calculus', 'Statistics', 'Physics', 'Chemistry', 'Biology', 'Physical Sciences', 'Life Sciences', 'English Home Language', 'English First Additional', 'Afrikaans', 'isiZulu', 'History', 'Geography', 'Psychology', 'Computer Science', 'Python Programming', 'Computer Applications Technology', 'Programming', 'Accounting', 'Business Studies', 'Economics', 'Financial Accounting', 'Engineering Mathematics', 'Circuit Analysis', 'Engineering Mechanics', 'Human Anatomy', 'Human Physiology', 'Nursing', 'Law Studies', 'Constitutional Law', 'Education Studies', 'Early Childhood Development', 'Agricultural Sciences', 'Environmental Science', 'Music Theory', 'Piano', 'Guitar', 'Visual Arts', 'Tourism', 'Engineering Science', 'Matric Final Exams', 'Study Skills', 'Research Methodology', 'Academic Writing'])
const legacySlugs = { 'C++ Programming': 'cpp-programming', 'Grade 8-11 Exams': 'grade-8-11-exams' }
export const subjectSlug = name => legacySlugs[name] || name.toLowerCase().replace(/&/g, ' and ').replace(/\+/g, ' plus ').replace(/#/g, ' sharp ').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
export const subjects = entries.map((subject, index) => ({ ...subject, slug: subjectSlug(subject.name), is_popular: popularNames.has(subject.name), sort_order: index }))
export const subjectCatalog = { version: 1, categories: subjectCategories, levels: educationLevels, subjects }
