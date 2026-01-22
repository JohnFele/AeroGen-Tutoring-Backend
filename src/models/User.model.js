import mongoose from "mongoose";
import bcrypt from "bcryptjs";

const { Schema, model } = mongoose;

const roles = ["student", "tutor", "admin", "superUser"];

const userSchema = new Schema(
  {
    firstName: { 
      type: String, 
      required: true,
      trim: true
    },
    lastName: { 
      type: String, 
      required: true,
      trim: true 
    },
    email: { 
      type: String, 
      required: true,
      trim: true, 
      lowercase: true, 
      unique: true,
      validate: {
        validator: (v) => /^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$/.test(v),
        message: 'Please enter a valid email address.'
      }
    },
    phone: { 
      type: String, 
      required: true,
      trim: true 
    },
    location: { 
      type: String, 
      required: true,
      trim: true 
    },
    role: {
      type: String,
      enum: roles,
      default: "student"
    },
    authProvider: {
      type: String,
      enum: ['local', 'google'],
      default: 'local',
    },
    password: { 
      type: String, 
      required: function() { return this.authProvider === 'local'; },
      select: false, 
    },
    bio: {
      type: String,
      default: "",
      trim: true
    },
    isVerified: { 
      type: Boolean, 
      default: false 
    },
    verificationCode: {
      type: String,
      required: false,
      select: false,
    },
    verificationCodeExpires: {
      type: Date,
      required: false,
      select: false,
    },

    // Password reset
    resetCode: {
      type: String,
      required: false,
      select: false,
    },
    resetCodeExpires: {
      type: Date,
      required: false,
      select: false,
    },

    // Refresh token for JWT refresh system
    tokenVersion: { 
      type: Number, 
      default: 0 
    }
  },
  { timestamps: true }
);

userSchema.index({ email: 1 }, { unique: true });

userSchema.pre("save", async function (next) {
  if (!this.isModified('password') || !this.password) return next();

  const salt = await bcrypt.genSalt(12);

  this.password = await bcrypt.hash(this.password, salt);
  next();
});

userSchema.methods.comparePassword = async function (candidatePassword) {
  if (!this.password) return false;
  return await bcrypt.compare(candidatePassword, this.password);
};

userSchema.methods.toJSON = function () {
  const obj = this.toObject();
  delete obj.password;
  delete obj.verificationCode;
  delete obj.verificationCodeExpires;
  delete obj.resetCode;
  delete obj.resetCodeExpires;
  delete obj.__v;
  return obj;
};

export default model("User", userSchema);
