import mongoose from 'mongoose';
const { Schema } = mongoose;

const PasswordResetTokenSchema = new Schema({
  tokenHash: { type: String, required: true },
  user: { type: Schema.Types.ObjectId, ref: 'User', required: true },
  createdAt: { type: Date, default: Date.now },
  expiresAt: { type: Date, required: true, index: true },
  used: { type: Boolean, default: false },
});

export const PasswordResetToken = mongoose.model('PasswordResetToken', PasswordResetTokenSchema);
