import nodemailer from 'nodemailer';
import { ENV } from '../config/env.js';

let transporter;
if (ENV.SMTP_HOST) {
  transporter = nodemailer.createTransport({
    host: ENV.SMTP_HOST,
    port: ENV.SMTP_PORT,
    secure: ENV.SMTP_PORT === 465,
    auth: {
      user: ENV.SMTP_USER,
      pass: ENV.SMTP_PASS,
    },
  });
}

export const sendEmail = async ({ to, subject, text, html }) => {
  if (!transporter) {
    console.log('No SMTP transporter configured. Email not sent.');
    console.log({ to, subject, text });
    return;
  }
  return transporter.sendMail({
    from: ENV.EMAIL_FROM,
    to,
    subject,
    text,
    html,
  });
};
