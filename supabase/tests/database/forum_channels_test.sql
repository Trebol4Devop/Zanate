-- =============================================================================
-- pgTAP: catálogo único de canales del foro (frontend ↔ Zanate-admin)
-- =============================================================================
begin;

select plan(10);

create extension if not exists pgtap;

select tests.create_supabase_user('dddddddd-dddd-dddd-dddd-dddddddddddd');
select tests.create_supabase_user('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee');

-- 1) Los canales que usa el frontend existen en el catálogo administrable
select results_eq(
    $$select id from public.categorias_foro
       where id in ('todos','general','prerrequisitos','catedraticos','apuntes','horarios','desahogo','desmadre')
       order by id$$,
    $$values ('apuntes'),('catedraticos'),('desahogo'),('desmadre'),
             ('general'),('horarios'),('prerrequisitos'),('todos')$$,
    '1. los 8 canales del frontend existen en categorias_foro'
);

-- 2) Todos los canales tienen metadatos de presentación
select ok(
    not exists (
        select 1 from public.categorias_foro
        where slug is null or btrim(slug) = ''
           or icon is null or btrim(icon) = ''
    ),
    '2. todos los canales tienen slug e icon'
);

-- 3) Orden explícito para que el frontend no lo hardcodee
select ok(
    (select count(*) from public.categorias_foro where sort_order > 0) >= 8,
    '3. los canales sembrados tienen sort_order > 0'
);

-- 4) El agregador "Todas las áreas" es de sistema
select ok(
    (select is_system from public.categorias_foro where id = 'todos'),
    '4. el canal todos está marcado is_system'
);

select tests.authenticate_as_admin('dddddddd-dddd-dddd-dddd-dddddddddddd');

-- 5) Un administrador puede crear un canal nuevo
select is(
    (public.admin_upsert_forum_category(
        jsonb_build_object(
            'id', 'becas',
            'nombre', 'Becas y Financiamiento',
            'descripcion', 'Convocatorias y apoyo económico.',
            'slug', 'becas-y-financiamiento',
            'icon', 'campaign_outlined',
            'sort_order', 90
        )
    ) ->> 'id'),
    'becas',
    '5. el administrador crea un canal nuevo'
);

-- 6) Los canales históricos del frontend son editables
select is(
    (public.admin_upsert_forum_category(
        jsonb_build_object(
            'id', 'general',
            'nombre', 'Consultas Generales',
            'descripcion', 'Avisos y vida universitaria (actualizado por admin).',
            'slug', 'charla-general',
            'icon', 'chat_bubble_outline',
            'sort_order', 20
        )
    ) #>> '{category,descripcion}'),
    'Avisos y vida universitaria (actualizado por admin).',
    '6. el administrador edita un canal existente del frontend'
);

select tests.authenticate_as_moderator('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee');

-- 7) Un moderador no puede gestionar el catálogo
select throws_ok(
    $$select public.admin_upsert_forum_category(
        jsonb_build_object('id', 'sanciones', 'nombre', 'Sanciones')
      )$$,
    '42501',
    null,
    '7. un moderador no puede crear canales (42501)'
);

select tests.authenticate_as_admin('dddddddd-dddd-dddd-dddd-dddddddddddd');

-- 8) El agregador no se puede eliminar
select throws_ok(
    $$select public.admin_delete_forum_category('todos')$$,
    '22023',
    null,
    '8. el canal todos no se puede eliminar'
);

-- 9) Un canal sin publicaciones se elimina físicamente
select is(
    (public.admin_delete_forum_category('becas') ->> 'deleted')::boolean,
    true,
    '9. el administrador elimina un canal sin publicaciones'
);

-- 10) La vista de administración expone los metadatos
select ok(
    exists (
        select 1 from public.v_forum_category_admin v
        where v.id = 'general'
          and v.slug = 'charla-general'
          and v.icon = 'chat_bubble_outline'
    ),
    '10. v_forum_category_admin expone slug e icon'
);

select * from finish();
rollback;
