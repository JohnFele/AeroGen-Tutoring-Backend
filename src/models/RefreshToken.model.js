// import mongoose from 'mongoose';
// import { generateRandomToken } from '../utils/jwt.util.js';
// const { Schema, model } = mongoose;

// const RefreshTokenSchema = new Schema(
//   {
//     tokenId: { 
//       type: String, 
//       unique: true,
//       sparse: true, 
//       default: () => generateRandomToken()
//     },
//     user: { 
//       type: Schema.Types.ObjectId, 
//       ref: 'User', 
//       required: true, 
//       index: true 
//     },
//     tokenHash: { 
//       type: String, 
//       required: true 
//     },
//     userAgent: {
//       type: String
//     },
//     ipAddress: { 
//       type: String
//     },
//     revoked: { 
//       type: Boolean, 
//       default: false
//     },
//     expiresAt: { 
//       type: Date, 
//       required: true 
//     }
//   },
//   { timestamps: true }
// );

// RefreshTokenSchema.index({ expiresAt: 1 }, { expireAfterSeconds: 0 });

// export const RefreshToken = model('RefreshToken', RefreshTokenSchema);
import mongoose from 'mongoose';
import crypto from 'crypto';
const { Schema, model } = mongoose;

// Optional: more secure tokenId generator
const generateId = () => crypto.randomBytes(16).toString("hex");

const RefreshTokenSchema = new Schema(
  {
    tokenId: {
      type: String,
      unique: true,
      sparse: true,
      default: generateId
    },

    user: {
      type: Schema.Types.ObjectId,
      ref: 'User',
      required: true,
      index: true
    },

    // Hash of the refresh token (not the token itself)
    tokenHash: {
      type: String,
      required: true,
      index: true         // speeds up lookups
    },

    userAgent: {
      type: String,
      default: ""
    },

    ipAddress: {
      type: String,
      default: ""
    },

    revoked: {
      type: Boolean,
      default: false,
      index: true
    },

    // Must always be set manually
    expiresAt: {
      type: Date,
      required: true
    }
  },
  {
    timestamps: true
  }
);

// TTL index – MongoDB automatically deletes after expiresAt
// Note: MongoDB TTL works only on Date fields and uses their value
// Deletion is not immediate; Mongo may take up to ~60s to run cleanup
RefreshTokenSchema.index({ expiresAt: 1 }, { expireAfterSeconds: 0 });

export const RefreshToken = model("RefreshToken", RefreshTokenSchema);
