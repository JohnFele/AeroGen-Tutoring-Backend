import { ENV } from '../config/env.config.js';

const supportRecipient = 'aerogentutoring@gmail.com';
const allowedTopics = new Set([
  'Account access', 'Profile', 'Sessions and bookings', 'Payments', 'Technical issue', 'Other',
]);

const escapeHtml = (value) => value
  .replaceAll('&', '&amp;')
  .replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;')
  .replaceAll('"', '&quot;')
  .replaceAll("'", '&#39;');

export const sendSupportRequest = async (req, res) => {
  const { name, email, topic, message } = req.body ?? {};
  const cleanName = typeof name === 'string' ? name.trim() : '';
  const cleanEmail = typeof email === 'string' ? email.trim() : '';
  const cleanTopic = typeof topic === 'string' ? topic : '';
  const cleanMessage = typeof message === 'string' ? message.trim() : '';

  if (!cleanName || cleanName.length > 120) {
    return res.status(400).json({ message: 'Enter your name (up to 120 characters).' });
  }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(cleanEmail) || cleanEmail.length > 254) {
    return res.status(400).json({ message: 'Enter a valid email address.' });
  }
  if (!allowedTopics.has(cleanTopic)) {
    return res.status(400).json({ message: 'Choose a valid support topic.' });
  }
  if (cleanMessage.length < 10 || cleanMessage.length > 4000) {
    return res.status(400).json({ message: 'Your message must be between 10 and 4000 characters.' });
  }
  if (!ENV.BREVO_API_KEY || !ENV.BREVO_SENDER_EMAIL) {
    return res.status(503).json({ message: 'Support email is not configured yet. Please try again later.' });
  }
  if (!ENV.BREVO_API_KEY.startsWith('xkeysib-')) {
    return res.status(503).json({ message: 'The backend needs a Brevo API key in BREVO_API_KEY; the SMTP key cannot authenticate this API integration.' });
  }

  const safeName = escapeHtml(cleanName);
  const safeEmail = escapeHtml(cleanEmail);
  const safeTopic = escapeHtml(cleanTopic);
  const safeMessage = escapeHtml(cleanMessage);
  const textContent = [
    'AeroGen Tutoring support request',
    `Name: ${cleanName}`,
    `Email: ${cleanEmail}`,
    `Topic: ${cleanTopic}`,
    '',
    cleanMessage,
  ].join('\n');
  const messageHtml = safeMessage.replaceAll('\n', '<br>');
  const receivedAt = new Intl.DateTimeFormat('en-ZA', {
    dateStyle: 'medium',
    timeStyle: 'short',
    timeZone: 'Africa/Johannesburg',
  }).format(new Date());
  const htmlContent = `<!doctype html>
<html lang="en">
  <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>AeroGen Tutoring support request</title></head>
  <body style="margin:0;padding:0;background-color:#f4f6fa;font-family:Arial,Helvetica,sans-serif;color:#263449;-webkit-text-size-adjust:100%;">
    <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="background-color:#f4f6fa;padding:32px 12px;">
      <tr><td align="center">
        <table role="presentation" width="600" cellspacing="0" cellpadding="0" border="0" style="width:100%;max-width:600px;background-color:#ffffff;border:1px solid #e5eaf2;border-radius:16px;overflow:hidden;box-shadow:0 8px 28px rgba(20,43,79,0.08);">
          <tr><td style="height:6px;background-color:#efad32;background-image:linear-gradient(90deg,#ffedaa 0%,#f9d65c 42%,#efad32 100%);font-size:0;line-height:0;">&nbsp;</td></tr>
          <tr><td style="padding:28px 32px 26px;background-color:#123b78;background-image:linear-gradient(130deg,#0b2f68 0%,#173f7c 58%,#37266e 100%);">
            <table role="presentation" cellspacing="0" cellpadding="0" border="0"><tr>
              <td align="center" valign="middle" width="46" height="46" style="width:46px;height:46px;border-radius:13px;background-color:#f9cf4f;background-image:linear-gradient(145deg,#ffdf72,#f0a92f);color:#123b78;font-size:17px;font-weight:800;letter-spacing:-1px;">AG</td>
              <td style="padding-left:13px;color:#ffffff;font-size:18px;line-height:24px;font-weight:700;">AeroGen Tutoring<span style="display:block;color:#d9e4f5;font-size:12px;line-height:18px;font-weight:400;">SUPPORT REQUEST</span></td>
            </tr></table>
          </td></tr>
          <tr><td style="padding:30px 32px 10px;">
            <p style="margin:0 0 7px;color:#6842a5;font-size:12px;line-height:18px;font-weight:700;letter-spacing:1.2px;text-transform:uppercase;">A new request has arrived</p>
            <h1 style="margin:0;color:#123b78;font-size:25px;line-height:32px;font-weight:700;">${safeTopic}</h1>
            <p style="margin:8px 0 0;color:#64748b;font-size:13px;line-height:20px;">Received ${receivedAt} (South Africa time)</p>
          </td></tr>
          <tr><td style="padding:18px 32px 8px;">
            <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="border:1px solid #e8eaf2;border-radius:12px;background-color:#fbfaff;">
              <tr><td style="padding:17px 18px 10px;color:#758096;font-size:11px;line-height:16px;font-weight:700;letter-spacing:.8px;text-transform:uppercase;">From</td></tr>
              <tr><td style="padding:0 18px 4px;color:#263449;font-size:15px;line-height:22px;font-weight:700;">${safeName}</td></tr>
              <tr><td style="padding:0 18px 17px;color:#6842a5;font-size:14px;line-height:21px;"><a href="mailto:${safeEmail}" style="color:#6842a5;text-decoration:underline;">${safeEmail}</a></td></tr>
            </table>
          </td></tr>
          <tr><td style="padding:14px 32px 30px;">
            <p style="margin:0 0 10px;color:#123b78;font-size:13px;line-height:19px;font-weight:700;">MESSAGE</p>
            <div style="padding:18px 20px;border-left:4px solid #efad32;border-radius:0 10px 10px 0;background-color:#fffaf0;color:#344256;font-size:14px;line-height:23px;overflow-wrap:anywhere;">${messageHtml}</div>
            <p style="margin:20px 0 0;color:#64748b;font-size:12px;line-height:19px;">Reply directly to this email to respond to ${safeName}.</p>
          </td></tr>
          <tr><td style="padding:17px 32px;border-top:1px solid #e8edf4;background-color:#f9fafc;color:#8290a3;font-size:11px;line-height:17px;">AeroGen Tutoring <span style="color:#c28b22;">•</span> Support inbox</td></tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>`;

  try {
    const response = await fetch('https://api.brevo.com/v3/smtp/email', {
      method: 'POST',
      headers: {
        accept: 'application/json',
        'api-key': ENV.BREVO_API_KEY,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        sender: { email: ENV.BREVO_SENDER_EMAIL, name: ENV.BREVO_SENDER_NAME },
        to: [{ email: supportRecipient, name: 'AeroGen Tutoring Support' }],
        replyTo: { email: cleanEmail, name: cleanName },
        subject: `[AeroGen Support] ${cleanTopic}`,
        textContent,
        htmlContent,
      }),
    });

    if (!response.ok) {
      const detail = await response.text();
      console.error('Brevo support email failed:', response.status, detail);
      return res.status(502).json({ message: 'We could not send your support request. Please try again shortly.' });
    }

    return res.status(202).json({ message: 'Your support request was sent. We’ll get back to you by email.' });
  } catch (error) {
    console.error('Brevo support email request failed:', error);
    return res.status(502).json({ message: 'We could not send your support request. Please try again shortly.' });
  }
};
