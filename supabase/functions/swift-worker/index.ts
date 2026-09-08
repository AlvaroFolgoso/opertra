// ============================================================================
// OPERTRA · Subida de fotos del trabajador (que entra con PIN, sin sesión)
// ============================================================================
//
// EL PROBLEMA QUE RESUELVE
//   Las reglas del bucket de Storage solo dejan SUBIR ficheros a usuarios con
//   sesión iniciada (rol 'authenticated'). El personal de obra entra con PIN,
//   que para Supabase es un usuario ANÓNIMO. Por eso, cuando un trabajador
//   intentaba adjuntar la FOTO de una incidencia (o su propia foto de perfil),
//   la subida se rechazaba y se caía el envío entero: creía que había
//   reportado la avería y no se guardaba nada.
//
// CÓMO LO RESUELVE
//   El trabajador manda aquí la foto junto a su worker_id y su PIN. Esta
//   función valida el PIN contra la ficha (igual que worker_login y las demás
//   funciones del trabajador), deduce la EMPRESA de esa ficha —nunca se fía de
//   un dato del navegador— y sube el fichero con permisos de servicio a la
//   carpeta de su empresa. Devuelve la ruta, que la app guarda en la fila.
//
// NOMBRE DESPLEGADO
//   En Supabase quedó con el slug 'swift-worker' (la dirección
//   /functions/v1/swift-worker no se puede cambiar una vez creada). La app la
//   llama por ese nombre. Este archivo es esa misma función.
//
// CÓMO SE (RE)DESPLIEGA
//   Por el editor del panel de Supabase (Edit function → pegar → Deploy), o
//   por CLI:  supabase functions deploy swift-worker --no-verify-jwt
//   (--no-verify-jwt: quien llama es el trabajador con PIN, no un usuario con
//    sesión; la seguridad la pone el PIN validado aquí dentro.)
//   IMPORTANTE: en Settings de la función, "Verify JWT" debe quedar EN OFF.
//   No hace falta crear ningún secreto nuevo: usa SUPABASE_URL y
//   SUPABASE_SERVICE_ROLE_KEY, que el proyecto ya tiene.
// ============================================================================

import { createClient } from 'jsr:@supabase/supabase-js@2';

// El navegador llama desde opertra.com a *.supabase.co: es otra dirección, así
// que hay que permitir la llamada (CORS) y responder a la comprobación previa.
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
};

function responder(cuerpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}

// Deja el nombre del fichero en algo seguro para una ruta (letras, números,
// punto, guion). Igual que limpiarNombre() en la app.
function limpiarNombre(nombre: string): string {
  return String(nombre || 'foto.jpg')
    .toLowerCase()
    .replace(/[^a-z0-9.\-_]/g, '-')
    .replace(/-+/g, '-')
    .slice(-60) || 'foto.jpg';
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return responder({ error: 'Solo se acepta POST.' }, 405);

  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return responder({ error: 'El envío no tiene el formato esperado.' }, 400);
  }

  const workerId = String(form.get('worker_id') || '').trim();
  const pin      = String(form.get('pin') || '').trim();
  const carpeta  = String(form.get('carpeta') || '').trim();
  const archivo  = form.get('archivo');

  if (!workerId || !pin) return responder({ error: 'Faltan los datos de acceso.' }, 400);
  // Solo estas dos carpetas: son las únicas que sube un trabajador.
  if (carpeta !== 'incidents' && carpeta !== 'profiles') {
    return responder({ error: 'Carpeta no permitida.' }, 400);
  }
  if (!(archivo instanceof File)) return responder({ error: 'No llegó ningún archivo.' }, 400);

  // Comprobación de tipo y tamaño también en el servidor (no solo en el móvil).
  const tipoMime = archivo.type || '';
  if (!tipoMime.startsWith('image/')) return responder({ error: 'Solo se admiten imágenes.' }, 400);
  if (archivo.size > 12 * 1024 * 1024) return responder({ error: 'La imagen es demasiado grande.' }, 413);

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // El guardia de la puerta: PIN correcto y trabajador de alta. La empresa se
  // saca de aquí, nunca de un parámetro del navegador.
  const { data: w, error: eW } = await supabase
    .from('workers')
    .select('id, company_id')
    .eq('id', workerId)
    .eq('pin', pin)
    .eq('active', true)
    .maybeSingle();

  if (eW) return responder({ error: 'No se pudo validar el acceso.' }, 500);
  if (!w) return responder({ error: 'PIN incorrecto.' }, 401);

  const ruta = `${w.company_id}/${carpeta}/${Date.now()}-${limpiarNombre(archivo.name)}`;

  const bytes = new Uint8Array(await archivo.arrayBuffer());
  const { error: eUp } = await supabase.storage
    .from('opertra')
    .upload(ruta, bytes, { contentType: tipoMime, upsert: false });

  if (eUp) return responder({ error: 'No se pudo guardar la imagen.' }, 500);

  return responder({ ruta }, 200);
});
