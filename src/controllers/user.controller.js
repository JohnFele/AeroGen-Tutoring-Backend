import User from "../models/User.model.js";

export const me = async (req, res, next) => {
  try {
    if (!req.userId) return res.status(401).json({ message: "Unauthorized" });

    const user = await User.findById(req.userId);
    if (!user) return res.status(404).json({ message: "User not found" });

    return res.status(200).json({
      message: "User profile fetched successfully.",
      user: user.toJSON(),
    });
  } catch (error) {
    next(error);
  }
};