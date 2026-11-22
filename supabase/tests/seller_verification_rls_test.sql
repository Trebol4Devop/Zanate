-- =============================================================================
-- pgTAP: verified seller gate and server-authoritative sponsorship flags
-- =============================================================================
begin;

select plan(5);

create extension if not exists pgtap;

do $$
begin
  perform tests.create_supabase_user('77777777-7777-7777-7777-777777777777');
  perform tests.create_supabase_user('88888888-8888-8888-8888-888888888888');
  insert into public.profiles (id)
  values
    ('77777777-7777-7777-7777-777777777777'),
    ('88888888-8888-8888-8888-888888888888')
  on conflict (id) do nothing;
end;
$$;

select tests.authenticate_as_aal1(
  '77777777-7777-7777-7777-777777777777'
);

select throws_ok(
  $$insert into public.marketplace_items (
      title, description, author_alias, user_id, contact_whatsapp
    ) values (
      'Anuncio no verificado', 'Debe ser rechazado', 'Estudiante Anónimo',
      '77777777-7777-7777-7777-777777777777', '50255551111'
    )$$,
  '42501',
  null,
  'Vendedor no verificado no puede publicar'
);

select tests.authenticate_as_admin(
  '88888888-8888-8888-8888-888888888888'
);

select is(
  (public.admin_upsert_merchant_profile(
    '77777777-7777-7777-7777-777777777777',
    'Comercio Verificado',
    null, null, null, 'free', 'approved', 'Verificacion admin de prueba'
  )->>'ok')::boolean,
  true,
  'El personal autorizado puede verificar al vendedor'
);

select tests.authenticate_as(
  '77777777-7777-7777-7777-777777777777'
);

select lives_ok(
  $$insert into public.marketplace_items (
      title, description, author_alias, user_id, is_sponsored,
      sponsor_badge_text, sponsor_brand_name, contact_whatsapp
    ) values (
      'Anuncio regular', 'Publicación de prueba', 'Estudiante Anónimo',
      '77777777-7777-7777-7777-777777777777', true,
      'Patrocinado', 'Marca falsa', '50255551111'
    )$$,
  'El vendedor verificado puede publicar pero no asignarse patrocinio'
);

-- Volver a rol postgres para verificaciones directas en la tabla marketplace_items
reset role;
set role postgres;
select set_config('request.jwt.claims', '', true);
select set_config('request.jwt.claim.sub', '', true);

select is(
  (select is_sponsored from public.marketplace_items
    where title = 'Anuncio regular'),
  false,
  'El trigger ignora el autopatrocinio enviado por el cliente'
);

select is(
  (select sponsor_brand_name from public.marketplace_items
    where title = 'Anuncio regular'),
  null::text,
  'El trigger elimina la marca que no aprobó el personal'
);

select * from finish();
rollback;
