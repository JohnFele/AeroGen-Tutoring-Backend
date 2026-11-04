import{createPublicSupabaseClient}from'../config/supabase.js';
export const platformColumns='applications,student_registration,maintenance,admin_email_notifications,version,updated_at';
export const platformDto=row=>({applications:row.applications,studentRegistration:row.student_registration,maintenance:row.maintenance,notifications:row.admin_email_notifications,version:row.version,updatedAt:row.updated_at});
export async function readPlatformSettings(client=createPublicSupabaseClient()){
  const{data,error}=await client.from('platform_settings').select(platformColumns).eq('id',true).single().abortSignal(AbortSignal.timeout(10000));if(error)throw error;if(!data)throw Error('Platform settings unavailable');return platformDto(data);
}
