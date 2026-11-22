-- =============================================================================
-- pgTAP: canales por servidor y moderación con scope de servidor
-- =============================================================================
begin;

select plan(9);

create extension if not exists pgtap;

select tests.create_supabase_user('a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1');
select tests.create_supabase_user('b2b2b2b2-b2b2-b2b2-b2b2-b2b2b2b2b2b2');

-- 1) Cada servidor de foro tiene su propio catálogo de canales
select ok(
    (select count(*) from public.forum_server_channels where server_id = 'sistemas') >= 7,
    '1. el servidor sistemas tiene su catálogo de canales'
);

-- 2) Varios servidores tienen canales independientes
select ok(
    (select count(distinct server_id) from public.forum_server_channels) >= 10,
    '2. al menos 10 servidores tienen canales propios'
);

-- 3) El canal "todos" es de sistema en cada servidor
select ok(
    not exists (
        select 1 from public.forum_server_channels
        where id = 'todos' and not is_system
    ),
    '3. el canal todos es de sistema en todos los servidores'
);

-- 4) La moderación de posts usa el servidor (carrera) como scope
select ok(
    position('new_row->>''carrera''' in
        pg_get_functiondef('public.check_content_moderation()'::regprocedure)) > 0,
    '4. check_content_moderation resuelve el scope por carrera/servidor'
);

select tests.authenticate_as_admin('a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1');

-- 5) Un administrador crea un canal propio del servidor
select is(
    (public.admin_upsert_forum_server_channel(jsonb_build_object(
        'server_id', 'sistemas',
        'id', 'proyectos',
        'nombre', 'Proyectos y Prácticas',
        'descripcion', 'Proyectos de curso y prácticas profesionales.',
        'icon', 'work_outline',
        'sort_order', 200
    )) ->> 'id'),
    'proyectos',
    '5. el administrador crea un canal en un servidor'
);

-- 6) El canal aparece solo en ese servidor
select ok(
    exists (select 1 from public.forum_server_channels where server_id = 'sistemas' and id = 'proyectos')
    and not exists (select 1 from public.forum_server_channels where server_id = 'civil' and id = 'proyectos'),
    '6. el canal nuevo es exclusivo del servidor sistemas'
);

-- 7) La vista de administración lo expone con el servidor
select ok(
    exists (
        select 1 from public.v_forum_server_channels_admin
        where server_id = 'sistemas' and id = 'proyectos'
    ),
    '7. v_forum_server_channels_admin expone el canal del servidor'
);

select tests.authenticate_as_moderator('b2b2b2b2-b2b2-b2b2-b2b2-b2b2b2b2b2b2');

-- 8) Un moderador no puede gestionar canales
select throws_ok(
    $$select public.admin_upsert_forum_server_channel(
        jsonb_build_object('server_id','sistemas','id','otro','nombre','Otro')
      )$$,
    '42501',
    null,
    '8. un moderador no puede gestionar canales por servidor (42501)'
);

select tests.authenticate_as_admin('a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1');

-- 9) El administrador elimina el canal creado
select is(
    (public.admin_delete_forum_server_channel('sistemas', 'proyectos') ->> 'deleted')::boolean,
    true,
    '9. el administrador elimina un canal sin publicaciones'
);

select * from finish();
rollback;
