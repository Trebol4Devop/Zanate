import { createClient } from 'npm:@supabase/supabase-js@2'
import webpush from 'npm:web-push@3.6.7'

// Los secretos ya NO viven en el código: se leen del Vault de la BD vía
// la RPC public.get_push_secrets() (solo accesible con service_role).

function resolveServiceKey(): string {
  try {
    const keys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}')
    if (keys['default']) return keys['default']
  } catch {
    // ignore
  }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_ANON_KEY') ?? ''
}

const supabase = createClient(Deno.env.get('SUPABASE_URL') ?? '', resolveServiceKey())

async function getPushSecrets(): Promise<{
  edgeSecret: string
  vapidPublic: string
  vapidPrivate: string
  vapidSubject: string
}> {
  const { data, error } = await supabase.rpc('get_push_secrets')
  if (error) {
    console.error('error fetching push secrets:', error.message)
    throw new Error('push secrets unavailable')
  }
  if (!data?.edge_secret || !data?.vapid_public || !data?.vapid_private || !data?.vapid_subject) {
    throw new Error('push secrets incomplete')
  }
  return {
    edgeSecret: data.edge_secret,
    vapidPublic: data.vapid_public,
    vapidPrivate: data.vapid_private,
    vapidSubject: data.vapid_subject,
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('method not allowed', { status: 405 })
  }

  let secrets
  try {
    secrets = await getPushSecrets()
  } catch (err) {
    console.error('failed to load push secrets:', err?.message ?? err)
    return new Response('server error', { status: 500 })
  }

  webpush.setVapidDetails(secrets.vapidSubject, secrets.vapidPublic, secrets.vapidPrivate)

  if (req.headers.get('x-pemtree-secret') !== secrets.edgeSecret) {
    return new Response('unauthorized', { status: 401 })
  }

  let notificationId: string | undefined
  try {
    const body = await req.json()
    notificationId = body?.notification_id
  } catch {
    return new Response('bad request', { status: 400 })
  }
  if (!notificationId) {
    return new Response('bad request', { status: 400 })
  }

  const { data: notif, error: notifErr } = await supabase
    .from('user_notifications')
    .select('id, user_id, title, body, post_id')
    .eq('id', notificationId)
    .maybeSingle()

  if (notifErr) {
    console.error('error fetching notification:', notifErr.message)
    return new Response('error', { status: 500 })
  }
  if (!notif) {
    return new Response('notification not found', { status: 404 })
  }

  const { data: subs, error: subsErr } = await supabase
    .from('notification_subscriptions')
    .select('id, endpoint, p256dh, auth')
    .eq('user_id', notif.user_id)

  if (subsErr) {
    console.error('error fetching subscriptions:', subsErr.message)
    return new Response('error', { status: 500 })
  }
  if (!subs || subs.length === 0) {
    await supabase
      .from('user_notifications')
      .update({ push_sent_at: new Date().toISOString() })
      .eq('id', notif.id)
    return new Response('no subscriptions', { status: 200 })
  }

  const url = notif.post_id ? `/foro?post=${notif.post_id}` : '/foro'
  const payload = JSON.stringify({ title: notif.title, body: notif.body, url })

  for (const sub of subs) {
    try {
      await webpush.sendNotification(
        { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
        payload,
        { TTL: 604800 }
      )
    } catch (err) {
      const status = Number(err?.statusCode) || 0
      if (status === 404 || status === 410) {
        await supabase.from('notification_subscriptions').delete().eq('id', sub.id)
      } else {
        console.error('push error', status, err?.message)
      }
    }
  }

  await supabase
    .from('user_notifications')
    .update({ push_sent_at: new Date().toISOString() })
    .eq('id', notif.id)

  return new Response('ok', { status: 200 })
})
