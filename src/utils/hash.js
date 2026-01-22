import bcrypt from 'bcryptjs';

export const hash = async (plaintext, rounds = 12) => {
  return bcrypt.hash(plaintext, rounds);
};

export const compare = async (plaintext, hashed) => {
  return bcrypt.compare(plaintext, hashed);
};
