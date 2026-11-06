import { readFileSync } from 'node:fs'

const cambridge = JSON.parse(readFileSync(new URL('./cambridgeSyllabuses.json', import.meta.url), 'utf8'))
const fetOutlines = JSON.parse(readFileSync(new URL('./capsFetOutlines.json', import.meta.url), 'utf8'))
const ncvMatrix = JSON.parse(readFileSync(new URL('./ncvSubjects2026.json', import.meta.url), 'utf8'))
const capsRoot = 'https://www.education.gov.za/Curriculum/CurriculumAssessmentPolicyStatements(CAPS)/'
const nsc = 'https://www.education.gov.za/Curriculum/NationalSeniorCertificate(NSC)Examinations.aspx'
const exam = 'https://www.education.gov.za/Curriculum/NationalSeniorCertificate(NSC)Examinations/ExamTimetable.aspx'
const policy = 'https://www.education.gov.za/LinkClick.aspx?fileticket=0KWF2Y_PF8w%3D&mid=1127&portalid=0&tabid=390'
const ieb = 'https://www.ieb.co.za/assessment/high-schools/national-senior-certificate'
const sacai = 'https://www.sacai.org.za/'
const cam = 'https://www.cambridgeinternational.org/programmes-and-qualifications/'
const ib = 'https://www.ibo.org/programmes/diploma-programme/curriculum/'
const ibSchools = 'https://www.ibo.org/about-the-ib/the-ib-by-country-and-territory/s/south-africa/'
const ibPyp = 'https://www.ibo.org/programmes/primary-years-programme/curriculum/'
const ibMyp = 'https://www.ibo.org/programmes/middle-years-programme/curriculum/'
const pearsonGcse = 'https://qualifications.pearson.com/en/qualifications/edexcel-international-gcses.a-z.html'
const pearsonAdvanced = 'https://qualifications.pearson.com/en/qualifications/edexcel-international-advanced-levels.html'
const dhet = 'https://www.dhet.gov.za/SitePages/'
const tertiaryDirectory = dhet + 'MasterLists.aspx'
const privateDirectory = dhet + 'DocRegisters.aspx'
const collegeGuides = dhet + 'DocCurriculumDocuments.aspx'
const ncvOutline = 'https://www.dhet.gov.za/Technical%20and%20Vocational%20Education%20and%20Training%20Co/2026%20National%20Certificate%20(Vocational)%20Subjects%20Matrix.pdf'
const exemption = 'https://usaf.ac.za/facilitating-entry-to-sa-universities/'
const sources = (...pairs) => pairs.map(([label, url]) => ({ label, url }))
const rows = (group, names, url) => names.split('|').map(name => ({ name, group, url }))

const officialLanguages = 'Afrikaans|English|isiNdebele|isiXhosa|isiZulu|Sepedi|Sesotho|Setswana|siSwati|Tshivenda|Xitsonga'
const languageRows = (names, level, url) => rows('Languages', names.split('|').map(language => `${language} ${level}`).join('|'), url)
const phaseUrls = { foundation: capsRoot + 'CAPSFoundation.aspx', intermediate: capsRoot + 'CAPSIntermediate.aspx', senior: capsRoot + 'CAPSSenior.aspx', fet: capsRoot + 'CAPSFET.aspx' }
const capsPhases = Object.fromEntries(Object.entries(phaseUrls).map(([phase,url]) => [phase, [
  ...languageRows(officialLanguages, 'Home Language', url),
  ...languageRows(officialLanguages, 'First Additional Language', url),
  { name: 'South African Sign Language Home Language', group: 'Languages', url },
  ...rows('Mathematics', 'Mathematics', url),
]]))
capsPhases.foundation.push(...rows('Life Skills', 'Life Skills', phaseUrls.foundation))
capsPhases.intermediate.push(...rows('General education', 'Life Skills|Natural Sciences and Technology|Social Sciences', phaseUrls.intermediate))
capsPhases.senior.push(...rows('General education', 'Natural Sciences|Social Sciences|Technology|Economic and Management Sciences|Creative Arts|Life Orientation', phaseUrls.senior))
const codingRollout = 'https://www.education.gov.za/Portals/0/Media/Parliamentary%20Questions/2025/WQ%2032%20NA%20.pdf?ver=2025-06-12-091410-740'
const coding = {
  foundation:'https://www.education.gov.za/Portals/0/CD/National%20Curriculum%20Statements%20and%20Vocational/FP%20Coding%20and%20Robotics%20CAPS%20Final%202025.pdf?ver=2025-10-27-133557-637',
  intermediate:'https://www.education.gov.za/Portals/0/CD/National%20Curriculum%20Statements%20and%20Vocational/Coding%20and%20Robotics%20IP%20Grade%204%20-%206.pdf?ver=2024-07-16-134236-860',
  senior:codingRollout,
}
for (const [phase,url] of Object.entries(coding)) capsPhases[phase].push({
  name:'Coding and Robotics', group:'Technology', url,
  outline:'Availability depends on school capacity and the grade-by-grade implementation. Confirm that your school offers it for your grade.',
})
capsPhases.fet.push(
  ...languageRows(officialLanguages, 'Second Additional Language', phaseUrls.fet),
  ...languageRows('German|Gujarati|Hindi|Portuguese|Tamil|Telugu|Urdu', 'Home Language', exam),
  ...languageRows('German|Gujarati|Hindi|Portuguese|Tamil|Telugu|Urdu', 'First Additional Language', exam),
  ...languageRows('Arabic|French|German|Gujarati|Hebrew|Hindi|Italian|Latin|Mandarin|Modern Greek|Portuguese|Serbian|Spanish|Tamil|Telugu|Urdu', 'Second Additional Language', exam),
  ...rows('Mathematics','Mathematical Literacy|Technical Mathematics',phaseUrls.fet),
  { name:'Physical Sciences', group:'Sciences', aliases:['Physics','Chemistry','Fisiese Wetenskappe'], outline:'Physics and chemistry form one subject. Grade 12 Paper 1 covers physics and Paper 2 covers chemistry. Use the CAPS document to check grade-specific content, practical work and assessment.', url:'https://www.education.gov.za/Portals/0/CD/National%20Curriculum%20Statements%20and%20Vocational/CAPS%20FET%20%20PHYSICAL%20SCIENCE%20WEB.pdf' },
  ...rows('Sciences','Life Sciences|Technical Sciences|Marine Sciences|Agricultural Sciences|Agricultural Management Practices|Agricultural Technology',phaseUrls.fet),
  ...rows('Commerce and services','Accounting|Business Studies|Economics|Consumer Studies|Hospitality Studies|Tourism|Maritime Economics',phaseUrls.fet),
  ...rows('Technology','Computer Applications Technology|Information Technology|Engineering Graphics and Design|Civil Technology|Electrical Technology|Mechanical Technology',phaseUrls.fet),
  ...rows('Humanities and wellbeing','Geography|History|Life Orientation|Religion Studies|Sport and Exercise Science',phaseUrls.fet),
  ...rows('Arts','Dance Studies|Design|Dramatic Arts|Music|Visual Arts',phaseUrls.fet),
  ...rows('Specialist options','Equine Studies|Nautical Science',phaseUrls.fet),
)
const dbeNames = { 'Agricultural Sciences':'Agricultural Science', Design:'Design Studies' }
for (const subject of capsPhases.fet) {
  if (subject.url === phaseUrls.fet) subject.url = fetOutlines[dbeNames[subject.name] || subject.name] || subject.url
}

const nscRequirements = [
  'The standard NSC package is seven subjects: a Home Language, a second official language at Home or First Additional level, a mathematics option, Life Orientation and three electives. Confirm permitted substitutions or extra subjects with your school.',
  'The standard pass requires at least 40% in the Home Language and two other subjects, and at least 30% in three more, with the prescribed assessments completed. Higher certificate, diploma and degree admission use separate thresholds. Institutions may require specific subjects, higher marks or additional selection.',
  'Use the CAPS syllabus, the current Annual Teaching Plan where applicable, and your assessment body’s current guidelines, practical tasks and examination timetable.',
]
const capsStage = {
  foundation: { title:'Foundation Phase · Grades R–3', notes:'Grade R focuses on Home Language, Mathematics and Life Skills. Grades 1–3 add First Additional Language. Use your school’s language combination and the correct grade outline.' },
  intermediate: { title:'Intermediate Phase · Grades 4–6', notes:'The core includes two languages, Mathematics, Natural Sciences and Technology, Social Sciences and Life Skills. Check the grade-specific assessment and promotion policy.' },
  senior: { title:'Senior Phase · Grades 7–9', notes:'The core includes two languages, Mathematics, Natural Sciences, Social Sciences, Technology, Economic and Management Sciences, Life Orientation and Creative Arts. Check the grade-specific programme and promotion rules.' },
  fet: { title:'Further Education and Training · Grades 10–12', notes:'Select the exact language level and mathematics option registered with the school. Specialist and additional languages depend on what the school and assessment body offer.' },
}
for (const [phase,url] of Object.entries(phaseUrls)) capsStage[phase].url = url
const capsPath = {
  levels:Object.keys(capsPhases), subjects:capsPhases, stages:capsStage,
  requirements:nscRequirements,
  sources:sources(['DBE programme and promotion policy · Grades R–12',policy],['DBE National Senior Certificate resources',nsc],['DBE exam timetable and registered subjects',exam]),
}
const ibGroups = [
  ['Language and literature','Language A: Literature|Language A: Language and Literature|Literature and Performance'],
  ['Language acquisition','Classical Languages|Language ab initio|Language B'],
  ['Individuals and societies','Business Management|Digital Society|Economics|Geography|Global Politics|History|Philosophy|Psychology|Social and Cultural Anthropology|World Religions'],
  ['Sciences','Biology|Chemistry|Computer Science|Design Technology|Physics|Sports, Exercise and Health Science'],
  ['Mathematics','Mathematics: Analysis and Approaches|Mathematics: Applications and Interpretation'],
  ['Arts','Dance|Film|Music|Theatre|Visual Arts'],
  ['Interdisciplinary','Environmental Systems and Societies'],
  ['Diploma core','Theory of Knowledge|Extended Essay|Creativity, Activity, Service'],
]
const cambridgeSubjects = list => list.map(({ name, syllabus, note, url }) => ({
  name, code:syllabus, group:'Cambridge syllabuses', url, ...(note ? { outline:note } : {}),
}))
const cambridgeEarly = (stage, names) => {
  const url = cam + `cambridge-${stage}/curriculum/`
  return names.split('|').map(entry => {
    const [name, code] = entry.split(':')
    return { name, code, url, group:'Cambridge subject frameworks' }
  })
}
const registerLinks = [['DHET public institutions and public colleges',tertiaryDirectory],['DHET private institutions and college registers',privateDirectory]]
const higherLinks = [...registerLinks,
  ['Council on Higher Education qualifications framework','https://www.che.ac.za/sites/default/files/inline-files/PUB_Higher%20Education%20Qualifications%20Sub-Framework%20%28HEQSF%29%202013.pdf'],
  ['Unisa guidance on credits and modules','https://www.unisa.ac.za/sites/corporate/default/Apply-for-admission/Student-fees-and-funding-your-studies/Qualifications%3A-credits%2C-modules-and-NQF-levels'],
]
const ncvSubjects = Object.entries(ncvMatrix).flatMap(([group, levels]) => {
  const subjects = new Map()
  levels.forEach((rows, index) => rows.forEach(raw => {
    const name = raw.replace(/\s*\(O\)\s*\*/g,'').trim()
    const optional = /\(O\)/.test(raw)
    const key = name + optional
    if (!subjects.has(key)) subjects.set(key, { name, group, nqf:[], ...(optional ? { optional:true } : {}) })
    const subject = subjects.get(key)
    if (!subject.nqf.includes(index + 2)) subject.nqf.push(index + 2)
  }))
  return [...subjects.values()]
})

export const pathways = [
  { ...capsPath, code:'caps-dbe', name:'CAPS / NSC · DBE', summary:'National curriculum used in public schools and by independent schools following DBE assessment.' },
  { code:'caps-ieb', name:'CAPS / NSC · IEB', levels:['fet'], subjectSource:'caps-dbe', stages:{fet:capsStage.fet}, requirements:nscRequirements, summary:'An independent assessment route for the South African NSC, based on CAPS. IEB publishes its own subject assessment guidelines.',
    sources:sources(['IEB NSC requirements and subject options',ieb],['IEB assessment guidelines',ieb + '/nsc-subject-assessment-guidelines'],['IEB achievement and admission categories',ieb + '/categories-of-achievement-in-the-nsc'],['DBE FET subject outlines',phaseUrls.fet]) },
  { code:'caps-sacai', name:'CAPS / NSC · SACAI', levels:['fet'], subjectSource:'caps-dbe', stages:{fet:capsStage.fet}, requirements:nscRequirements, summary:'SACAI assesses the CAPS-based NSC for registered providers. Confirm your centre’s registered subjects and assessment instructions.',
    sources:sources(['SACAI NSC guidance',sacai],['SACAI 2026 examination guide',sacai + 'wp-content/uploads/NSC-Exam-Guide.pdf'],['DBE FET subject outlines',phaseUrls.fet]) },
  { code:'cambridge-primary', name:'Cambridge Primary', levels:['foundation','intermediate'], sharedSubjects:cambridgeEarly('primary','English:0058|English as a Second Language:0057|Mathematics:0096|Science:0097|Global Perspectives:0838|Art and Design:0067|Physical Education:0069|Music:0068|Digital Literacy:0072|Computing:0059|Wellbeing:0034|Humanities:0065|Modern Foreign Language:0064'),
    summary:'Cambridge Primary typically covers Stages 1–6. A school can combine it with a national programme and choose its offered subjects.',
    requirements:['Use the school’s Cambridge stage and subject framework. Progression Tests and Checkpoint are assessment options, depending on the school.'],
    sources:sources(['Cambridge Primary curriculum and subject frameworks',cam + 'cambridge-primary/curriculum/']) },
  { code:'cambridge-lower-secondary', name:'Cambridge Lower Secondary', levels:['senior'], sharedSubjects:cambridgeEarly('lower-secondary','English:0861|English as a Second Language:0876|Mathematics:0862|Science:0893|Global Perspectives:1129|Art and Design:0073|Physical Education:0081|Music:0078|Digital Literacy:0082|Computing:0860|Wellbeing:0859|Humanities:0839|Modern Foreign Language:0771'),
    summary:'Cambridge Lower Secondary normally covers Stages 7–9. The school chooses its combination of subjects.',
    requirements:['Check your stage, school assessment plan and whether you will take Lower Secondary Checkpoint.'],
    sources:sources(['Cambridge Lower Secondary curriculum and subject frameworks',cam + 'cambridge-lower-secondary/curriculum/']) },
  { code:'cambridge-igcse', name:'Cambridge IGCSE', levels:['senior','fet'], sharedSubjects:cambridgeSubjects(cambridge.igcse),
    summary:'Cambridge Upper Secondary qualification. Physics and Chemistry are separate syllabuses. The course stage is set by the school.',
    requirements:['Use the syllabus code and examination year. Some subjects have different grading scales, components or entry options. Ask your school which are available.'],
    sources:sources(['Cambridge IGCSE subject index and syllabuses',cam + 'cambridge-upper-secondary/cambridge-igcse/subjects/'],['South African university entry and exemptions',exemption]) },
  { code:'cambridge-as-a', name:'Cambridge International AS & A Level', levels:['fet'], sharedSubjects:cambridgeSubjects(cambridge.advanced),
    summary:'Cambridge Advanced qualifications, with AS and A Level options that vary by syllabus.',
    requirements:['Confirm the exact syllabus code, AS-only or A Level route, paper combination and examination year. Check both the Matriculation Board and your institution for South African university admission.'],
    sources:sources(['Cambridge AS & A Level subject index and syllabuses',cam + 'cambridge-advanced/cambridge-international-as-and-a-levels/subjects/'],['South African university entry and exemptions',exemption]) },
  { code:'ib-dp', name:'International Baccalaureate Diploma Programme', levels:['fet'], sharedSubjects:ibGroups.flatMap(([group,names]) => rows(group,names,ib)),
    summary:'Two-year Diploma Programme from an authorised IB World School. Subjects are offered at Standard or Higher Level depending on the school.',
    requirements:['The diploma normally uses six subjects, including three or four at Higher Level, plus Theory of Knowledge, the Extended Essay and Creativity, Activity, Service. At least 24 points and the additional IB passing conditions are required.'],
    sources:sources(['IB subject briefs and core outlines',ib],['IB Diploma passing criteria','https://www.ibo.org/about-the-ib/what-it-means-to-be-an-ib-student/recognizing-student-achievement/about-assessment/dp-passing-criteria/'],['IB World Schools in South Africa',ibSchools],['South African university entry and exemptions',exemption]) },
  { code:'ib-pyp', name:'International Baccalaureate Primary Years Programme', levels:['foundation','intermediate'],
    sharedSubjects:rows('PYP learning areas','Language|Mathematics|Science|Social Studies|Arts|Personal, Social and Physical Education',ibPyp),
    summary:'The PYP is an inquiry-based curriculum framework. Each authorised school develops its own programme of inquiry across the learning areas.',
    requirements:['Use the school’s current unit of inquiry, learning outcomes and assessment evidence. Ask your school how the unit connects to the learning area you want help with.'],
    sources:sources(['IB Primary Years curriculum',ibPyp],['IB World Schools in South Africa',ibSchools]) },
  { code:'ib-myp', name:'International Baccalaureate Middle Years Programme', levels:['senior','fet'],
    sharedSubjects:rows('MYP subject groups','Language Acquisition|Language and Literature|Individuals and Societies|Sciences|Mathematics|Arts|Physical and Health Education|Design',ibMyp),
    summary:'The MYP combines subject groups with interdisciplinary work. Use your school’s MYP year and actual subject combination.',
    requirements:['Check the subject brief and school assessment criteria. Years 4 and 5 allow some subject choice, and the programme includes a long-term project.'],
    sources:sources(['IB Middle Years subject briefs and curriculum',ibMyp],['IB World Schools in South Africa',ibSchools]) },
  { code:'pearson-igcse', name:'Pearson Edexcel International GCSE', levels:['senior','fet'],
    sharedSubjects:rows('International GCSE specifications','Accounting|Arabic (First Language)|Art and Design|Bangla|Bangladesh Studies|Biology|Business|Chemistry|Chinese|Commerce|Computer Science|Economics|English as a Second Language|English Language Specification A|English Language Specification B|English Literature|French|Further Pure Mathematics|Geography|German|Global Citizenship|Greek (First Language)|History|Human Biology|Information and Communication Technology (ICT)|Islamic Studies|Mathematics Specification A|Mathematics Specification B|Pakistan Studies|Physics|Religious Studies|Science Single Award|Science Double Award|Sinhala|Spanish|Swahili|Tamil',pearsonGcse),
    summary:'International GCSE specifications include separate sciences and combined award routes. Exam series and available specifications vary by subject.',
    requirements:['Use the specification, route and exam series registered by your school or centre.'],
    sources:sources(['Pearson International GCSE subjects, specifications and exam availability',pearsonGcse],['South African university entry and exemptions',exemption]) },
  { code:'pearson-ial', name:'Pearson Edexcel International Advanced Level', levels:['fet'],
    sharedSubjects:rows('International Advanced Level specifications','Accounting|Arabic|Biology|Business|Chemistry|Economics|English Language|English Literature|French|Geography|German|Greek|History|Information Technology|Law|Mathematics|Further Mathematics|Physics|Psychology|Spanish',pearsonAdvanced),
    summary:'Pearson International AS and A Levels are distinct qualifications. Check which units and exam series are offered for your subject.',
    requirements:['Confirm your specification and unit entry with the school or exam centre. University applicants should check exemption and programme-specific admission requirements.'],
    sources:sources(['Pearson International Advanced Level subjects, specifications and exam availability',pearsonAdvanced],['South African university entry and exemptions',exemption]) },
  { code:'ncv', name:'National Certificate (Vocational) · NC(V)', levels:['college'], sharedSubjects:ncvSubjects, institutionSpecific:true,
    summary:'A vocational route at NQF levels 2–4. The DHET subject matrix specifies the subjects for each vocational programme and level.',
    requirements:['At each level, check the three fundamental subjects and the four vocational subjects against the current DHET matrix. Confirm the language of teaching, mathematics option, internal assessment and practical requirements with your college.'],
    sources:sources(['DHET 2026 NC(V) subject matrix',ncvOutline],['DHET assessment guidelines and programme syllabuses',collegeGuides],...registerLinks) },
  { code:'report-191', name:'Report 191 / NATED · N programmes', levels:['college'], institutionSpecific:true,
    summary:'National vocational programmes identified by an N level, programme and subject. Availability and teach-out schedules depend on the qualification and provider.',
    requirements:['Check the latest DHET syllabus and registration availability for the programme and N level. For a National N Diploma, check the provider’s requirements for the applicable theory certificates and relevant workplace experience.'],
    sources:sources(['DHET Report 191 syllabuses, assessment and circulars',collegeGuides],...registerLinks) },
  { code:'occupational', name:'Occupational qualifications and trades', levels:['college','adult'], institutionSpecific:true,
    summary:'Public and private providers may offer QCTO occupational qualifications and trade pathways. Check accreditation for the exact programme and delivery site.',
    requirements:['Confirm the registered qualification or skills programme, SAQA ID, relevant knowledge and practical components, workplace requirements and external assessment.'],
    sources:sources(['Quality Council for Trades and Occupations','https://www.qcto.org.za/'],['SAQA registered qualifications search','https://allqs.saqa.org.za/'],...registerLinks) },
  { code:'higher-public', name:'Public universities and universities of technology', levels:['undergraduate','postgraduate'], institutionSpecific:true,
    summary:'South African universities publish their own module codes, prerequisite rules and year-specific handbooks. The national framework defines qualification types.',
    requirements:['Choose the institution, qualification, year and exact module code. Check prerequisites or co-requisites, credits, learning outcomes and assessment in the current institutional handbook.'],
    sources:sources(...higherLinks) },
  { code:'higher-private', name:'Registered private higher education institutions', levels:['college','undergraduate','postgraduate'], institutionSpecific:true,
    summary:'Use the DHET register to check the provider and its registered qualification. Each institution sets the module structure and assessment for its programme.',
    requirements:['Check the registered qualification and delivery site, then use the institution’s handbook for exact modules, outcomes, assessment and progression rules.'],
    sources:sources(...higherLinks) },
  { code:'adult-education', name:'Adult education and matric completion', levels:['adult'], institutionSpecific:true,
    summary:'Identify whether you are preparing for an adult education qualification, a Senior Certificate or an NSC rewrite. These routes have different entry and assessment requirements.',
    requirements:['Ask your centre to confirm your registered qualification, examination year and which subjects or learning areas you can take.'],
    sources:sources(['DBE adult Senior Certificate subjects and admission','https://www.education.gov.za/Curriculum/SeniorCertificate.aspx'],['DBE examinations and matric guidance',nsc],['SACAI adult education and NSC assessment',sacai],...registerLinks) },
  { code:'other', name:'Other school curriculum or qualification', levels:['foundation','intermediate','senior','fet','college','undergraduate','postgraduate','adult'], institutionSpecific:true,
    summary:'Use this route for a school programme, qualification or module that is specific to your provider or missing from the index.',
    requirements:['Include the official curriculum or qualification name, institution, grade or year, exact subject or module and a link to the current outline if available.'],
    sources:sources(['DHET institution directories',tertiaryDirectory],['South African university entry and exemptions',exemption]) },
]
