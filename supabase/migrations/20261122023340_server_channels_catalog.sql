-- =============================================================================
-- Zanate · Canales por servidor y moderación a nivel de servidor
-- Fecha: 2026-11-22
-- =============================================================================
-- Cambios:
--   1) forum_server_channels: cada espacio tiene su propio catálogo de canales.
--   2) Sembrado inicial: plantilla global (categorias_foro) por cada servidor.
--   3) check_content_moderation: el scope de moderación de posts pasa de
--      `category` (canal) a `carrera` (servidor).
--   4) Políticas: se replica la política posts/default por servidor.
--   5) RPCs y vista de administración de canales por servidor.
-- =============================================================================

create table if not exists public.forum_server_channels (
    server_id   text not null references public.forum_servers(id) on delete cascade,
    id          text not null,
    nombre      text not null,
    slug        text,
    descripcion text,
    icon        text not null default 'tag',
    sort_order  integer not null default 0,
    is_active   boolean not null default true,
    is_system   boolean not null default false,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    primary key (server_id, id),
    constraint forum_server_channels_id_format check (id ~ '^[a-z0-9][a-z0-9_-]{1,39}$')
);

comment on table public.forum_server_channels is
  'Canales de tema por servidor del foro. Cada espacio puede tener un catálogo distinto.';

create index if not exists idx_server_channels_order
  on public.forum_server_channels (server_id, sort_order, id)
  where is_active;

-- Sembrar la plantilla global en cada servidor de foro (no grupos).
insert into public.forum_server_channels
  (server_id, id, nombre, slug, descripcion, icon, sort_order, is_active, is_system)
select
  s.id, c.id, c.nombre, c.slug, c.descripcion, c.icon, c.sort_order, c.is_active,
  (c.id = 'todos')
from public.forum_servers s
join public.categorias_foro c on c.is_active
where not s.is_groups
on conflict (server_id, id) do nothing;

alter table public.forum_server_channels enable row level security;

drop policy if exists "Lectura de canales por servidor (anon)" on public.forum_server_channels;
drop policy if exists "Lectura de canales por servidor (auth)" on public.forum_server_channels;

create policy "Lectura de canales por servidor (anon)"
  on public.forum_server_channels for select to anon
  using (is_active = true);

create policy "Lectura de canales por servidor (auth)"
  on public.forum_server_channels for select to authenticated
  using (
    is_active = true
    or public.is_pemtree_admin((select auth.uid()))
    or public.is_pemtree_moderator((select auth.uid()))
  );

revoke insert, update, delete on public.forum_server_channels from anon, authenticated;
grant select on public.forum_server_channels to anon, authenticated;
grant all on public.forum_server_channels to service_role;

-- Políticas por servidor: replicar la política base de posts/default.
insert into public.moderation_policies (
  entity_table, scope_key, allow_colloquial_profanity, allow_external_links,
  require_verified_user, laya_thresholds, escalation_margin, report_score_to_hide
)
select
  'posts', s.carrera_id, p.allow_colloquial_profanity, p.allow_external_links,
  p.require_verified_user, p.laya_thresholds, p.escalation_margin, p.report_score_to_hide
from public.forum_servers s
join public.moderation_policies p
  on p.entity_table = 'posts' and p.scope_key = 'default'
where s.show_in_rail and not s.is_groups
  and s.carrera_id is not null
  and s.carrera_id <> 'default'
on conflict (entity_table, scope_key) do nothing;
