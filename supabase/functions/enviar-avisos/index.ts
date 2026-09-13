// ============================================================================
// OPERTRA · Avisos push de fin de jornada (llegan con la app cerrada)
// ============================================================================
//
// QUÉ HACE
//   Cada minuto (la lanza el reloj de la base de datos, pg_cron, por pg_net)
//   busca jornadas abiertas cuya hora prevista de terminar ya ha llegado y
//   que aún no se han avisado, y manda a los móviles de esos trabajadores el
//   aviso "¿Has terminado? No olvides fichar la salida". Llega aunque la app
//   esté cerrada: es una notificación push de verdad.
//
// CLAVES VAPID
//   El push exige un par de claves (pública/privada). Se generan AQUÍ la
//   primera vez que arranca la función y se guardan en la tabla push_config
//   (RLS cerrada: solo el servidor la lee). Nadie tiene que copiar ni pegar
//   una clave privada. La pública la lee la app por push_clave_publica().
//
// SEGURIDAD
//   Solo responde si llega la cabecera Authorization: Bearer <AVISOS_SECRET>
//   (secreto de Edge Functions). Lo único que hace es un barrido idempotente,
//   pero así nadie de fuera puede lanzarlo a lo loco.
//
// SECRETOS QUE NECESITA (Edge Functions → Secrets)
//   OPERTRA_SERVICE_KEY  clave sb_secret_ del proyecto (ya existe)
//   AVISOS_SECRET        el secreto que también va en el cron
//
// DESPLIEGUE
//   Panel Supabase → Edge Functions → Deploy a new function → nombre EXACTO
//   "enviar-avisos" → pegar este archivo → Deploy. "Verify JWT" en OFF (quien
//   llama es el cron con su secreto, no un usuario con sesión).
//
// PRUEBA MANUAL
//   POST con el mismo Bearer y cuerpo {"prueba": true, "worker_id": "<uuid>"}
//   manda un aviso de prueba a ese trabajador ahora mismo.
// ============================================================================

import { createClient } from 'jsr:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

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

// ---- base64url <-> bytes (para montar la clave pública VAPID) -------------
function b64uABytes(s: string): Uint8Array {
  const pad = '='.repeat((4 - s.length % 4) % 4);
  const b = atob((s + pad).replace(/-/g, '+').replace(/_/g, '/'));
  const out = new Uint8Array(b.length);
  for (let i = 0; i < b.length; i++) out[i] = b.charCodeAt(i);
  return out;
}
function bytesAB64u(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// Genera un par de claves VAPID (curva P-256) con la criptografía del propio
// Deno. La pública va en formato "raw" (65 bytes, 0x04 + x + y) y la privada
// es el escalar d, ambos en base64url: justo lo que espera web-push.
async function generarVapid(): Promise<{ publica: string; privada: string }> {
  const kp = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const jwk = await crypto.subtle.exportKey('jwk', kp.privateKey) as JsonWebKey;
  const x = b64uABytes(jwk.x!), y = b64uABytes(jwk.y!);
  const pub = new Uint8Array(65);
  pub[0] = 4; pub.set(x, 1); pub.set(y, 33);
  return { publica: bytesAB64u(pub), privada: jwk.d! };
}

function clienteServicio() {
  const clave = Deno.env.get('OPERTRA_SERVICE_KEY')
             || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
             || '';
  return createClient(Deno.env.get('SUPABASE_URL')!, clave);
}

// Claves VAPID: se leen de push_config; si no existen todavía, se crean.
async function clavesVapid(supabase: any): Promise<{ vapid_public: string; vapid_private: string }> {
  const leer = async () => {
    const { data } = await supabase.from('push_config')
      .select('vapid_public, vapid_private').eq('id', 1).maybeSingle();
    return data || null;
  };
  let cfg = await leer();
  if (cfg) return cfg;
  const k = await generarVapid();
  const { error } = await supabase.from('push_config')
    .insert({ id: 1, vapid_public: k.publica, vapid_private: k.privada });
  if (error) {
    // Carrera: otra ejecución las creó un instante antes. Se usan las suyas.
    cfg = await leer();
    if (cfg) return cfg;
    throw new Error('No se pudieron guardar las claves VAPID: ' + error.message);
  }
  return { vapid_public: k.publica, vapid_private: k.privada };
}

type Sub = { id: string; worker_id: string; endpoint: string; p256dh: string; auth: string };

// Manda un aviso a todas las suscripciones de una lista. Devuelve cuántos
// llegaron y qué suscripciones ya no existen (móvil que quitó el permiso,
// app desinstalada...), para borrarlas y no insistir.
async function enviarA(subs: Sub[], payload: string): Promise<{ enviados: number; caducadas: string[] }> {
  let enviados = 0; const caducadas: string[] = [];
  for (const s of subs) {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        payload,
        { TTL: 3600 },
      );
      enviados++;
    } catch (e: any) {
      const st = e && e.statusCode;
      if (st === 404 || st === 410) caducadas.push(s.id);
      else console.error('push fallido:', st, e && (e.body || e.message));
    }
  }
  return { enviados, caducadas };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return responder({ error: 'Solo se acepta POST.' }, 405);

  // El guardia: solo el cron (o quien tenga el secreto)
  const secreto = Deno.env.get('AVISOS_SECRET') || '';
  const auth = req.headers.get('authorization') || '';
  if (!secreto || auth !== 'Bearer ' + secreto) return responder({ error: 'No autorizado.' }, 401);

  let body: any = {};
  try { body = await req.json(); } catch { body = {}; }

  const supabase = clienteServicio();

  let cfg;
  try { cfg = await clavesVapid(supabase); }
  catch (e: any) { console.error('vapid:', e); return responder({ error: 'Sin claves VAPID.' }, 500); }
  webpush.setVapidDetails('mailto:soporte@opertra.com', cfg.vapid_public, cfg.vapid_private);

  const ahora = new Date();

  // ---- Aviso de PRUEBA a un trabajador concreto, ahora mismo --------------
  if (body && body.prueba === true && body.worker_id) {
    const { data: subs } = await supabase.from('push_subscriptions')
      .select('id, worker_id, endpoint, p256dh, auth').eq('worker_id', body.worker_id);
    if (!subs || !subs.length) return responder({ enviados: 0, motivo: 'Ese trabajador no tiene ningún móvil suscrito.' }, 200);
    const payload = JSON.stringify({
      title: 'Opertra · Prueba de avisos',
      body: 'Si ves esto, los avisos te llegarán aunque tengas la app cerrada.',
      tag: 'prueba', url: '/',
    });
    const r = await enviarA(subs as Sub[], payload);
    if (r.caducadas.length) await supabase.from('push_subscriptions').delete().in('id', r.caducadas);
    return responder({ enviados: r.enviados, suscripciones: subs.length, caducadas: r.caducadas.length }, 200);
  }

  // ---- Barrido normal: jornadas cuya hora prevista ya ha llegado ----------
  // Ventana de 30 minutos hacia atrás: lo más viejo ya no tiene sentido
  // avisarlo (y no se quiere despertar a nadie con jornadas de ayer).
  const { data: logs, error: eL } = await supabase.from('time_logs')
    .select('id, worker_id, expected_end')
    .is('check_out', null)
    .is('aviso_enviado_at', null)
    .lte('expected_end', ahora.toISOString())
    .gte('expected_end', new Date(ahora.getTime() - 30 * 60000).toISOString())
    .limit(500);
  if (eL) { console.error('leer jornadas:', eL); return responder({ error: 'No se pudieron leer las jornadas.' }, 500); }
  if (!logs || !logs.length) return responder({ jornadas: 0, enviados: 0 }, 200);

  const ids = [...new Set(logs.map((l: any) => l.worker_id))];
  const { data: subs } = await supabase.from('push_subscriptions')
    .select('id, worker_id, endpoint, p256dh, auth').in('worker_id', ids);
  const porTrabajador = new Map<string, Sub[]>();
  (subs || []).forEach((s: Sub) => {
    if (!porTrabajador.has(s.worker_id)) porTrabajador.set(s.worker_id, []);
    porTrabajador.get(s.worker_id)!.push(s);
  });

  const payload = JSON.stringify({
    title: 'Opertra · ¿Has terminado?',
    body: 'Tenías previsto terminar sobre ahora. No olvides fichar la salida.',
    tag: 'fin-jornada', url: '/',
  });

  let enviados = 0; const caducadas: string[] = []; const avisados: string[] = [];
  for (const l of logs as any[]) {
    const lista = porTrabajador.get(l.worker_id) || [];
    if (lista.length) {
      const r = await enviarA(lista, payload);
      enviados += r.enviados; caducadas.push(...r.caducadas);
    }
    // Se marca como avisada aunque no tuviera móvil suscrito: no tiene
    // sentido volver a mirarla cada minuto durante media hora.
    avisados.push(l.id);
  }

  if (avisados.length) await supabase.from('time_logs').update({ aviso_enviado_at: ahora.toISOString() }).in('id', avisados);
  if (caducadas.length) await supabase.from('push_subscriptions').delete().in('id', caducadas);

  return responder({ jornadas: logs.length, enviados, suscripciones_caducadas: caducadas.length }, 200);
});
