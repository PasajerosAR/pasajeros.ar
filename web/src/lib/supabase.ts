import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const configured = Boolean(url && key && !url.includes('TU-PROYECTO'));

// Si falta la configuracion se usa un cliente inerte y la app muestra instrucciones.
export const supabase = createClient(
  configured ? url! : 'http://localhost:54321',
  configured ? key! : 'sin-configurar'
);
