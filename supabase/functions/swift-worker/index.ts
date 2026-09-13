// ============================================================================
// OPERTRA · Fotos del trabajador que entra con PIN (sin sesión)
// ============================================================================
//
// DOS COSAS EN UNA MISMA FUNCIÓN
//   · SUBIR   (multipart/form-data): guarda la foto en la carpeta de su empresa.
//   · ENLACES (application/json):    firma enlaces de lectura de fotos, SOLO de
//                                    su empresa. Sin esto el trabajador no veía
//                                    la foto de ninguna máquina ni incidencia:
//                                    la regla de lectura del bucket solo deja
//                                    a 'authenticated', y él es anónimo.
//
// SEGURIDAD
//   Se valida el PIN aquí dentro y la EMPRESA se deduce de la ficha, nunca de
//   un dato del navegador. En "enlaces" solo se firman rutas que empiecen por
//   la carpeta de su empresa: no puede pedir fotos de otra.
//
// CLAVE CON LA QUE HABLA CON LA BASE
//   Este proyecto usa el sistema NUEVO de claves de Supabase (sb_publishable_ /
//   sb_secret_). La antigua SUPABASE_SERVICE_ROLE_KEY que Supabase inyecta ya
//   no vale aquí. Por eso lee el secreto OPERTRA_SERVICE_KEY (Edge Functions →
//   Secrets), que contiene la clave sb_secret_ del proyecto. Además, el rol
//   service_role necesita SELECT sobre public.workers (se le devolvió el
//   2026-09-13; en la auditoría se le había quitado por error).
//
// NOMBRE DESPLEGADO
//   Slug 'swift-worker' (la dirección /functions/v1/swift-worker no se puede
//   cambiar una vez creada). En el panel aparece como 'subir-archivo-trabajador'.
//
// CÓMO SE (RE)DESPLIEGA
//   Panel de Supabase: Functions → subir-archivo-trabajador → Code → pegar →
//   Deploy. "Verify JWT" en OFF (quien llama es el trabajador con PIN).
// ============================================================================

import { createClient } from 'jsr:@supabase/supabase-js@2';

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

// Deja el nombre del fichero en algo seguro para una ruta. Igual que
// limpiarNombre() en la app.
function limpiarNombre(nombre: string): string {
  return String(nombre || 'foto.jpg')
    .toLowerCase()
    .replace(/[^a-z0-9.\-_]/g, '-')
    .replace(/-+/g, '-')
    .slice(-60) || 'foto.jpg';
}

function clienteServicio() {
  const clave = Deno.env.get('OPERTRA_SERVICE_KEY')
             || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
             || '';
  return createClient(Deno.env.get('SUPABASE_URL')!, clave);
}

// El guardia de la puerta: PIN correcto y trabajador de alta. Devuelve la
// empresa de la ficha, o null si el PIN no vale.
async function empresaDelTrabajador(supabase: any, workerId: string, pin: string): Promise<string | null> {
  const { data: w, error } = await supabase
    .from('workers')
    .select('id, company_id')
    .eq('id', workerId)
    .eq('pin', pin)
    .eq('active', true)
    .maybeSingle();
  if (error) throw error;
  return w ? w.company_id : null;
}

// ---- ENLACES DE LECTURA (application/json) --------------------------------
async function darEnlaces(req: Request): Promise<Response> {
  let body: any;
  try { body = await req.json(); } catch { return responder({ error: 'Formato no válido.' }, 400); }

  const workerId = String(body.worker_id || '').trim();
  const pin      = String(body.pin || '').trim();
  const rutas    = Array.isArray(body.rutas) ? body.rutas.map((r: unknown) => String(r || '')).filter(Boolean) : [];

  if (!workerId || !pin) return responder({ error: 'Faltan los datos de acceso.' }, 400);
  if (!rutas.length) return responder({ enlaces: {} }, 200);

  const supabase = clienteServicio();
  let company: string | null;
  try {
    company = await empresaDelTrabajador(supabase, workerId, pin);
  } catch (e) {
    console.error('validar acceso (enlaces):', e);
    return responder({ error: 'No se pudo validar el acceso.' }, 500);
  }
  if (!company) return responder({ error: 'PIN incorrecto.' }, 401);

  // Solo fotos de SU empresa: cualquier otra ruta se ignora.
  const prefijo = `${company}/`;
  const permitidas = rutas.filter((r: string) => r.startsWith(prefijo));
  if (!permitidas.length) return responder({ enlaces: {} }, 200);

  const { data: firmadas, error } = await supabase.storage
    .from('opertra')
    .createSignedUrls(permitidas, 3600);
  if (error) {
    console.error('firmar enlaces:', error);
    return responder({ error: 'No se pudieron generar los enlaces.' }, 500);
  }

  const enlaces: Record<string, string> = {};
  (firmadas || []).forEach((f: any, i: number) => {
    const ruta = (f && f.path) || permitidas[i];
    if (f && f.signedUrl && ruta) enlaces[ruta] = f.signedUrl;
  });
  return responder({ enlaces }, 200);
}

// ---- SUBIDA DE FOTO (multipart/form-data) ---------------------------------
async function subirFoto(req: Request): Promise<Response> {
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

  // Tipo y tamaño también en el servidor (no solo en el móvil).
  const tipoMime = archivo.type || '';
  if (!tipoMime.startsWith('image/')) return responder({ error: 'Solo se admiten imágenes.' }, 400);
  if (archivo.size > 12 * 1024 * 1024) return responder({ error: 'La imagen es demasiado grande.' }, 413);

  const supabase = clienteServicio();

  let company: string | null;
  try {
    company = await empresaDelTrabajador(supabase, workerId, pin);
  } catch (e) {
    console.error('validar acceso (subida):', e);
    return responder({ error: 'No se pudo validar el acceso.' }, 500);
  }
  if (!company) return responder({ error: 'PIN incorrecto.' }, 401);

  const ruta = `${company}/${carpeta}/${Date.now()}-${limpiarNombre(archivo.name)}`;

  const bytes = new Uint8Array(await archivo.arrayBuffer());
  const { error: eUp } = await supabase.storage
    .from('opertra')
    .upload(ruta, bytes, { contentType: tipoMime, upsert: false });

  if (eUp) {
    console.error('subir foto:', eUp);
    return responder({ error: 'No se pudo guardar la imagen.' }, 500);
  }

  return responder({ ruta }, 200);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return responder({ error: 'Solo se acepta POST.' }, 405);

  // JSON = pedir enlaces de lectura; cualquier otra cosa = subir foto.
  const contentType = req.headers.get('content-type') || '';
  if (contentType.includes('application/json')) {
    return await darEnlaces(req);
  }
  return await subirFoto(req);
});
