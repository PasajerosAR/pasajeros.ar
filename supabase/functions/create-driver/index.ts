// Edge Function de Supabase (Deno). Crea el usuario de un conductor para la empresa del administrador que llama.
// Necesita el service role, por eso no puede hacerse desde el navegador.
// NO PROBADA en este entorno (requiere un proyecto de Supabase real): ver README.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const authHeader = req.headers.get('Authorization') ?? '';

    // 1. quien llama: debe ser administrador de empresa
    const asCaller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: authHeader } } });
    const { data: who } = await asCaller.auth.getUser();
    if (!who.user) return json({ error: 'No autenticado.' }, 401);

    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: caller } = await admin.from('profiles').select('company_id, role, active').eq('id', who.user.id).maybeSingle();
    if (!caller || !caller.active || caller.role !== 'company_admin' || !caller.company_id) {
      return json({ error: 'Solo un administrador de empresa puede crear conductores.' }, 403);
    }

    // 2. validar datos
    const b = await req.json();
    const full_name = String(b.full_name ?? '').trim();
    const email = String(b.email ?? '').trim().toLowerCase();
    const password = String(b.password ?? '');
    if (!full_name) return json({ error: 'Falta el nombre.' }, 400);
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: 'El correo no es válido.' }, 400);
    if (password.length < 8) return json({ error: 'La contraseña debe tener al menos 8 caracteres.' }, 400);

    // 3. crear usuario y perfil; si falla el perfil se deshace el usuario
    const { data: created, error: e1 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
    if (e1 || !created.user) return json({ error: e1?.message ?? 'No se pudo crear el usuario.' }, 400);

    const { error: e2 } = await admin.from('profiles').insert({
      id: created.user.id, company_id: caller.company_id, role: 'driver', full_name,
      dni: String(b.dni ?? '').trim() || null, phone: String(b.phone ?? '').trim() || null
    });
    if (e2) {
      await admin.auth.admin.deleteUser(created.user.id);
      return json({ error: e2.message }, 400);
    }
    return json({ id: created.user.id });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
