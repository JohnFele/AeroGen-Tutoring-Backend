import{createPublicSupabaseClient}from'../config/supabase.js';
import{readPlatformSettings}from'./platformSettings.js';
import{deliverSupportEmail}from'../controllers/support.controller.js';
export function createApplicationNotifier({getClient=createPublicSupabaseClient,load=readPlatformSettings,deliver=deliverSupportEmail}={}){
  return async({id,application})=>{try{
    const client=getClient(),settings=await load(client);if(!settings.notifications)return{skipped:true};
    const{data:contact,error}=await client.from('site_contact_settings').select('email').eq('id',true).single().abortSignal(AbortSignal.timeout(10000));if(error)throw error;
    return await deliver({name:`${application.firstName} ${application.lastName}`.slice(0,120),email:application.email,topic:'Other',message:`A new tutor application is ready for review.\nReference: ${id}\nApplicant: ${application.firstName} ${application.lastName}\nSubjects: ${application.subjects.join(', ')}\n\nOpen Company actions → Tutor applications in the admin dashboard to review it. Identity documents remain in private storage.`},{recipient:contact.email,siteSubject:'[AeroGen] New tutor application',title:'New tutor application'});
  }catch{console.error('Application saved; admin email notification is unavailable.');return{status:503}}};
}
export const notifyApplicationAdmins=createApplicationNotifier();
