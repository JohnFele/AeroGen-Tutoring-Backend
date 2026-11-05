const missingSchema = new Set(['PGRST202', 'PGRST205', '42P01', '42883']);

export const isBookingSchemaUnavailable = error => missingSchema.has(error?.code);
