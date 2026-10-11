import { createClient } from '@supabase/supabase-js';
import { firebaseAuth } from './firebase';

const supabaseUrl = import.meta.env.PUBLIC_SUPABASE_URL;
const publishableKey = import.meta.env.PUBLIC_SUPABASE_PUBLISHABLE_KEY;

if (!supabaseUrl || !publishableKey) {
  throw new Error('Supabase public client configuration is incomplete.');
}

export const supabaseClient = createClient(supabaseUrl, publishableKey, {
  accessToken: async () => firebaseAuth.currentUser?.getIdToken() ?? null,
});
