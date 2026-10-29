import { decodeApplicationFile } from './applicationFiles.js';
import { sendSupportRequest } from './support.controller.js';
import { educationLevels } from '../data/subjectCatalog.js';

const categories = new Set(['general', 'tutoring', 'billing', 'technical', 'partnership', 'careers', 'talent', 'other']);
const text = (value, max = 1000) => typeof value === 'string' && value.trim().length <= max ? value.trim() : '';

export const sendSubjectRequest = (req, res) => {
  const body = req.body || {};
  if (body.website) return res.status(400).json({ message: 'Unable to submit this request.' });
  const limits = { firstName: 60, lastName: 60, email: 254, subjectName: 150, moduleCode: 60, institution: 150, educationLevel: 40, programme: 120, studyYear: 80, lessonMode: 20, location: 150, helpNeeded: 2000 };
  const fields = {};
  for (const [field, limit] of Object.entries(limits)) {
    if (body[field] !== undefined && (typeof body[field] !== 'string' || body[field].length > limit)) return res.status(400).json({ message: `Enter a valid ${field.replace(/([A-Z])/g, ' $1').toLowerCase()} (up to ${limit} characters).` });
    fields[field] = (body[field] || '').trim();
  }
  const level = educationLevels.find(level => level.code === fields.educationLevel);
  if (!fields.firstName || !fields.lastName || fields.subjectName.length < 2 || !level || fields.helpNeeded.length < 20) return res.status(400).json({ message: 'Enter your name, subject or module name, education level and at least 20 characters describing the help you need.' });
  if (['college', 'undergraduate', 'postgraduate'].includes(fields.educationLevel) && fields.institution.length < 2) return res.status(400).json({ message: 'Enter your college or university name so we can understand the module requirements.' });
  if (!['online', 'in-person', 'either'].includes(fields.lessonMode)) return res.status(400).json({ message: 'Choose your preferred lesson format.' });
  if (fields.lessonMode === 'in-person' && fields.location.length < 2) return res.status(400).json({ message: 'Enter your city or area for in-person tutoring.' });
  req.body = {
    name: `${fields.firstName} ${fields.lastName}`.slice(0, 120), email: fields.email, topic: 'Other',
    message: [
      'Unlisted subject / university module request',
      `Subject or module: ${fields.subjectName}`,
      `Module code: ${fields.moduleCode || 'Not supplied'}`,
      `Education level: ${level.name}`,
      `Institution: ${fields.institution || 'Not supplied'}`,
      `Degree / programme: ${fields.programme || 'Not supplied'}`,
      `Grade / year of study: ${fields.studyYear || 'Not supplied'}`,
      `Lesson format: ${fields.lessonMode}`,
      `City / area: ${fields.location || 'Not supplied'}`,
      '', 'Help needed:', fields.helpNeeded,
    ].join('\n'),
  };
  req.siteSubject = '[AeroGen] Subject or university module request';
  req.siteSuccessMessage = 'Your subject request was sent. The team will email you about possible tutoring options.';
  return sendSupportRequest(req, res);
};

export const sendEnquiry = (req, res) => {
  const { firstName, lastName, email, category, message, website } = req.body || {};
  if (website) return res.status(400).json({ message: 'Unable to submit this enquiry.' });
  if (!text(firstName, 60) || !text(lastName, 60) || !categories.has(category)) return res.status(400).json({ message: 'Enter your name and select an enquiry subject.' });
  if (typeof message !== 'string' || message.trim().length < 10 || message.length > 3500) return res.status(400).json({ message: 'Enter a message between 10 and 3500 characters.' });
  req.body = { name: `${firstName.trim()} ${lastName.trim()}`.slice(0, 120), email, topic: 'Other', message: `Website enquiry · ${category}\n\n${message.trim()}` };
  req.siteSubject = `[AeroGen Enquiry] ${category}`;
  req.siteSuccessMessage = 'Your enquiry was sent to AeroGen Tutoring. We will reply by email.';
  return sendSupportRequest(req, res);
};

export function validateApplication(body) {
  const data = body?.application;
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('Complete the tutor application.');
  const limits={firstName:60,lastName:60,email:254,phone:22,idNumber:100,address:1000,city:160,province:40,highestQualification:250,institution:250,yearCompleted:4,yearsExperience:10,teachingStyle:1000,hourlyRate:10,studentsPerSession:20,previousPlatforms:1000,certifications:1000};
  for(const [field,max] of Object.entries(limits)){if(data[field]!==undefined&&(typeof data[field]!=='string'||data[field].length>max))throw new Error(`Enter a valid ${field} (up to ${max} characters).`);}
  const required = ['firstName', 'lastName', 'email', 'phone', 'idNumber', 'address', 'city', 'province', 'highestQualification', 'institution', 'yearCompleted', 'yearsExperience', 'teachingStyle', 'hourlyRate'];
  for (const field of required) if (!text(data[field])) throw new Error(`Complete the ${field.replace(/([A-Z])/g, ' $1').toLowerCase()} field.`);
  for (const field of ['subjects', 'studentAgeGroups', 'availability', 'teachingMode']) {
    if (!Array.isArray(data[field]) || !data[field].length || data[field].length > 30 || data[field].some((item) => !text(item, 100))) throw new Error(`Choose your ${field.replace(/([A-Z])/g, ' $1').toLowerCase()}.`);
  }
  if (!/^\+?[\d\s()-]{9,22}$/.test(data.phone) || data.phone.replace(/\D/g,'').length<9 || data.phone.replace(/\D/g,'').length>15 || !Number.isFinite(Number(data.hourlyRate)) || Number(data.hourlyRate) < 100 || Number(data.hourlyRate) > 1000) throw new Error('Enter a valid phone number and an hourly rate between R100 and R1,000.');
  if (!/^\d{4}$/.test(data.yearCompleted) || Number(data.yearCompleted) < 1950 || Number(data.yearCompleted) > new Date().getFullYear()) throw new Error('Enter a valid qualification year.');
  const documents = body.documents;
  if (!Array.isArray(documents) || documents.length < 2 || documents.length > 3) throw new Error('Attach your ID document and qualification certificate.');
  const seen = new Set();
  const attachments = documents.map((file) => {
    if (!['idDocument', 'qualificationDocument', 'resume'].includes(file?.kind) || seen.has(file.kind)) throw new Error('Choose one file for each document type.');
    seen.add(file.kind);
    const decoded=decodeApplicationFile(file);
    return { name: decoded.uploadName, content: file.content };
  });
  if (!seen.has('idDocument') || !seen.has('qualificationDocument')) throw new Error('Attach your ID document and qualification certificate.');
  const allowedFields = [...required, 'subjects', 'studentAgeGroups', 'availability', 'teachingMode', 'studentsPerSession', 'previousPlatforms', 'certifications'];
  const message = allowedFields.map((field) => `${field.replace(/([A-Z])/g, ' $1')}: ${Array.isArray(data[field]) ? data[field].join(', ') : text(data[field])}`).join('\n');
  return { name: `${data.firstName.trim()} ${data.lastName.trim()}`.slice(0, 120), email: data.email, message, attachments };
}
