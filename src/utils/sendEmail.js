import nodemailer from "nodemailer";
import { ENV } from "../config/env.js";

export const sendEmail = async (to, subject, text) => {
  const transporter = nodemailer.createTransport({
    service: "gmail", // or any SMTP
    auth: {
      user: ENV.EMAIL_USER,
      pass: ENV.EMAIL_PASS,
    },
  });

  await transporter.sendMail({
    from: `"MyApp" <${ENV.EMAIL_USER}>`,
    to,
    subject,
    text,
  });
};
