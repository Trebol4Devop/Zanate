-- =============================================================================
-- pgTAP: catálogo de espacios del foro (rail, grupos y carreras)
-- =============================================================================
begin;

select plan(12);

create extension if not exists pgtap;

select tests.create_supabase_user('ffffffff-ffff-ffff-ffff-ffffffffffff');
select tests.create_supabase_user('abababab-abab-abab-abab-abababababab');

-- 1) Servidores curados del rail
select ok(
    (select count(*) from public.forum_servers
      where show_in_rail and is_active
        and id in ('todas','grupos_estudio','area_comun','sistemas','civil','industrial',
                   'medicina','derecho','arquitectura','economicas','agronomia')) = 11,
    '1. los 11 servidores del rail existen y están activos'
);

-- 2) Subservidores de Grupos
select ok(
    (select count(*) from public.forum_servers where is_groups and id like 'groups_%') >= 12,
    '2. existen los subservidores de Grupos de Estudio'
);

-- 3) Espacios "Todas las Carreras de <Facultad>"
select results_eq(
    $$select nombre from public.forum_servers where id = 'fac_01_todas'$$,
    $$values ('Todas las Carreras de Agronomía')$$,
    '3. existe el espacio Todas las Carreras de Agronomía'
);

-- 4) Resto del catálogo académico
select ok(
    exists (select 1 from public.forum_servers where id = '06-00-01'),
    '4. las carreras del catálogo académico están sembradas'
);

-- 5) Metadatos válidos para el frontend
select ok(
    not exists (
        select 1 from public.forum_servers
        where color_hex !~ '^#[0-9A-Fa-f]{6}$'
           or icon is null or btrim(icon) = ''
           or sort_order < 0
    ),
    '5. todos los espacios tienen color, icono y orden válidos'
);

-- 6) El servidor general es de sistema
select ok(
    (select is_system from public.forum_servers where id = 'todas'),
    '6. el servidor todas está marcado is_system'
);

select tests.authenticate_as_admin('ffffffff-ffff-ffff-ffff-ffffffffffff');

-- 7) Un administrador crea un espacio
select is(
    (public.admin_upsert_forum_server(jsonb_build_object(
        'id', 'becas',
        'nombre', 'Becas y Financiamiento',
        'descripcion', 'Convocatorias y apoyo económico.',
        'icon', 'campaign_outlined',
        'color_hex', '#0EA5E9',
        'facultad_id', 'todas',
        'facultad_nombre', 'Todas las Facultades',
        'carrera_id', 'becas',
        'show_in_rail', true,
        'sort_order', 120
    )) ->> 'id'),
    'becas',
    '7. el administrador crea un espacio en el rail'
);

-- 8) El espacio creado aparece en la vista de administración
select ok(
    exists (
        select 1 from public.v_forum_servers_admin v
        where v.id = 'becas' and v.color_hex = '#0EA5E9' and v.show_in_rail
    ),
    '8. v_forum_servers_admin expone el espacio creado'
);

select tests.authenticate_as_moderator('abababab-abab-abab-abab-abababababab');

-- 9) Un moderador no puede gestionar espacios
select throws_ok(
    $$select public.admin_upsert_forum_server(jsonb_build_object('id','otro','nombre','Otro'))$$,
    '42501',
    null,
    '9. un moderador no puede crear espacios (42501)'
);

select tests.authenticate_as_admin('ffffffff-ffff-ffff-ffff-ffffffffffff');

-- 10) El servidor de sistema no se puede eliminar
select throws_ok(
    $$select public.admin_delete_forum_server('todas')$$,
    '22023',
    null,
    '10. el servidor de sistema no se puede eliminar'
);

-- 11) Un espacio sin publicaciones se elimina físicamente
select is(
    (public.admin_delete_forum_server('becas') ->> 'deleted')::boolean,
    true,
    '11. el administrador elimina un espacio sin publicaciones'
);

-- 12) La eliminación quedó registrada y el espacio ya no existe
select ok(
    not exists (select 1 from public.forum_servers where id = 'becas'),
    '12. el espacio eliminado ya no está en el catálogo'
);

select * from finish();
rollback;
