// ============================================================================
// OPERTRA · Webhook de posición GPS
// ============================================================================
//
// QUÉ HACE
// Recibe la posición de UN localizador y la guarda en la máquina que tenga
// ese mismo código vinculado (columna machines.device_id, lo que se pone en
// la app al pulsar "Vincular dispositivo GPS" en la ficha de la máquina).
// A partir de ahí, el mapa de flota de la app se actualiza solo — ya está
// escuchando esos cambios por Supabase Realtime.
//
// POR QUÉ ES ASÍ, GENÉRICO
// Cuando escribí esto todavía no habías comprado los localizadores, así que
// no sé qué marca vas a usar ni cómo manda cada una sus datos. Prácticamente
// cualquier plataforma de flotas (sea cual sea la marca) sabe avisar a una
// URL cuando cambia una posición ("webhook"/"HTTP push"), o si no lo sabe
// hacer directamente, se puede escribir un script muy pequeño que cada
// minuto le pregunte a la API del fabricante "¿dónde están mis GPS?" y
// llame a esta URL por cada uno. Esta función es el punto de entrada común
// para cualquiera de los dos casos: no hay que tocar nada de la app ni de
// esta función el día que compres los localizadores, solo:
//   1. Poner en cada máquina (dentro de la app) el código del localizador
//      que lleva puesto.
//   2. Apuntar esa plataforma (o el script puente) a esta URL.
//
// CÓMO SE LLAMA
//   POST https://<tu-proyecto>.supabase.co/functions/v1/gps-webhook
//   Cabecera:  x-webhook-secret: <el secreto que pongas, ver más abajo>
//   Cuerpo (JSON):
//     { "device_id": "GPS-00123", "lat": 37.3891, "lng": -5.9845 }
//
// CÓMO SE INSTALA (una vez)
//   1. Instala el CLI de Supabase si no lo tienes: npm i -g supabase
//   2. Desde la carpeta del proyecto: supabase login
//                                      supabase link --project-ref <tu-project-ref>
//   3. Elige un secreto tuyo (una contraseña larga, invéntatela) y guárdalo:
//        supabase secrets set GPS_WEBHOOK_SECRET=pon-aqui-algo-largo-y-al-azar
//   4. Despliega la función:
//        supabase functions deploy gps-webhook --no-verify-jwt
//      (--no-verify-jwt: la protección aquí es el secreto de arriba, no un
//       usuario de la app — quien llama es la plataforma del GPS, no una
//       persona con sesión iniciada)
//   5. La URL que te da ese comando es la que configuras en la plataforma
//      del fabricante del localizador (o en el script puente).
// ============================================================================

import { createClient } from 'jsr:@supabase/supabase-js@2';

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Solo se acepta POST.' }), { status: 405 });
  }

  const secretoEsperado = Deno.env.get('GPS_WEBHOOK_SECRET');
  if (!secretoEsperado) {
    // Sin secreto configurado, nadie pasa: mejor eso que dejarlo abierto por
    // despiste de olvidarse de fijar el secreto al desplegar.
    return new Response(JSON.stringify({ error: 'GPS_WEBHOOK_SECRET no está configurado en el proyecto.' }), { status: 500 });
  }
  if (req.headers.get('x-webhook-secret') !== secretoEsperado) {
    return new Response(JSON.stringify({ error: 'Secreto incorrecto.' }), { status: 401 });
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'El cuerpo debe ser JSON válido.' }), { status: 400 });
  }

  const deviceId = String(body?.device_id || '').trim();
  const lat = Number(body?.lat);
  const lng = Number(body?.lng);

  if (!deviceId) {
    return new Response(JSON.stringify({ error: 'Falta device_id.' }), { status: 400 });
  }
  if (!Number.isFinite(lat) || lat < -90 || lat > 90 || !Number.isFinite(lng) || lng < -180 || lng > 180) {
    return new Response(JSON.stringify({ error: 'lat/lng no son coordenadas válidas.' }), { status: 400 });
  }

  // Service role: hace falta para escribir sin que RLS lo bloquee, porque
  // quien llama aquí no es un usuario con sesión de la app, es la
  // plataforma del GPS.
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const { data, error } = await supabase
    .from('machines')
    .update({ lat, lng, gps_updated_at: new Date().toISOString() })
    .eq('device_id', deviceId)
    .eq('device_linked', true)
    .select('id, code')
    .maybeSingle();

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  }
  if (!data) {
    // No es un error del que llama (el localizador manda bien su código),
    // es que en la app todavía no se ha vinculado ese código a ninguna
    // máquina. Se devuelve 404 para que quien integre la plataforma del
    // GPS lo note y no se quede pensando que ya está todo enchufado.
    return new Response(JSON.stringify({ error: `Ninguna máquina tiene vinculado el dispositivo "${deviceId}".` }), { status: 404 });
  }

  return new Response(JSON.stringify({ ok: true, machine_code: data.code }), { status: 200 });
});
