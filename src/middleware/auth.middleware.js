import { verifyAccessToken } from "../utils/jwt.util.js";

export const authorize = (req, res, next) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader) return res.status(401).json({ message: "Missing authorization header" });

    const parts = authHeader.split(" ");

    if (parts.length !== 2 || parts[0] !== "Bearer") return res.status(401).json({ message: "Invalid authorization header format" });

    const token = parts[1];
    const payload = verifyAccessToken(token);

    req.userId = payload.userId;
    req.userRole = payload.role;

    next();
  } catch (error) {
    return res.status(401).json({ message: "Invalid or expired access token" });
  }
};

export const authorizeRole = (allowedRoles) => {
  try {
    if (!req.userRole) return res.status(403).json({ message: "User role not found" });

    const allowedArray = Array.isArray(allowedRoles) ? allowedRoles : [allowedRoles];

    if (!allowedArray.includes(req.userRole)) {
      return res.status(403).json({ message: "Forbidden: Insufficient permissions" });
    }

    next();
  } catch (error) {
    next(error);
  }
};