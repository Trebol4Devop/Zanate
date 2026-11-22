-- ============================================================================
-- PEMTREE: Migración 05 - Sistema de Monitorización de Comentarios,
-- Moderación Avanzada y Filtro Antipalabrotas (Profanity & Toxicity Guard)
-- ============================================================================

-- Habilitar extensión unaccent si está disponible para normalización de caracteres
CREATE EXTENSION IF NOT EXISTS unaccent;

-- ----------------------------------------------------------------------------
-- 1. Extensiones a la Tabla Existente `comments`
-- ----------------------------------------------------------------------------
ALTER TABLE public.comments
    ADD COLUMN IF NOT EXISTS is_flagged boolean DEFAULT false,
    ADD COLUMN IF NOT EXISTS flag_reason text,
    ADD COLUMN IF NOT EXISTS toxicity_score real DEFAULT 0.0,
    ADD COLUMN IF NOT EXISTS profanity_matches text[] DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS is_deleted boolean DEFAULT false,
    ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
    ADD COLUMN IF NOT EXISTS deleted_by uuid REFERENCES auth.users(id),
    ADD COLUMN IF NOT EXISTS auto_moderated boolean DEFAULT false;

-- Índices optimizados para consultas del panel administrativo y monitor en vivo
CREATE INDEX IF NOT EXISTS idx_comments_moderation_status ON public.comments(moderation_status);
CREATE INDEX IF NOT EXISTS idx_comments_is_flagged ON public.comments(is_flagged) WHERE is_flagged = true;
CREATE INDEX IF NOT EXISTS idx_comments_post_created ON public.comments(post_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_comments_parent_id ON public.comments(parent_id) WHERE parent_id IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 2. Tabla: Diccionario Dinámico de Palabras Prohibidas (`profanity_dictionary`)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profanity_dictionary (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    term text NOT NULL UNIQUE,                -- Ejemplo: 'cerote', 'hdp', 'estúpido'
    normalized_term text NOT NULL,           -- Normalizado sin tildes ni leet (ej. 'cerote')
    category text NOT NULL CHECK (category IN (
        'insulto_grave',     -- Ataques personales directos
        'vulgaridad_comun',   -- Modismos soeces no necesariamente dirigidos a alguien
        'discriminacion',     -- Racismo, xenofobia, homofobia, clasismo
        'acoso_sexual',       -- Contenido o insinuaciones inapropiadas
        'spam_fraude'         -- Estafas, cripto, venta de parciales, fraude académico
    )),
    severity_level integer NOT NULL CHECK (severity_level BETWEEN 1 AND 3),
    -- Nivel 1: Enmascarar con asteriscos (c****e) pero permitir publicación
    -- Nivel 2: Marcar como 'Requiere revisión' (status = 3) y alertar al staff
    -- Nivel 3: Bloqueo preventivo inmediato (status = 2: Oculto)
    action_type text NOT NULL DEFAULT 'flag' CHECK (action_type IN ('mask', 'flag', 'block')),
    match_mode text NOT NULL DEFAULT 'exact' CHECK (match_mode IN ('exact', 'contains', 'regex')),
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at timestamptz DEFAULT timezone('utc'::text, now()) NOT NULL,
    created_by uuid REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_profanity_normalized ON public.profanity_dictionary(normalized_term) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_profanity_category ON public.profanity_dictionary(category);
CREATE INDEX IF NOT EXISTS idx_profanity_severity ON public.profanity_dictionary(severity_level);

-- Habilitar RLS en profanity_dictionary
ALTER TABLE public.profanity_dictionary ENABLE ROW LEVEL SECURITY;

-- Políticas RLS:
-- Moderadores y Admins pueden ver reglas
DROP POLICY IF EXISTS "Staff can read profanity_dictionary" ON public.profanity_dictionary;
CREATE POLICY "Staff can read profanity_dictionary"
    ON public.profanity_dictionary
    FOR SELECT
    TO authenticated
    USING (
        public.is_pemtree_admin(auth.uid()) OR 
        public.is_pemtree_moderator(auth.uid())
    );

-- Admins pueden gestionar reglas completamente
DROP POLICY IF EXISTS "Admins can manage profanity_dictionary" ON public.profanity_dictionary;
CREATE POLICY "Admins can manage profanity_dictionary"
    ON public.profanity_dictionary
    FOR ALL
    TO authenticated
    USING (public.is_pemtree_admin(auth.uid()))
    WITH CHECK (public.is_pemtree_admin(auth.uid()));

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.profanity_dictionary TO authenticated;

-- ----------------------------------------------------------------------------
-- 3. Tabla: Registro de Sanciones y Silenciamientos (`user_forum_strikes`)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_forum_strikes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    comment_id uuid REFERENCES public.comments(id) ON DELETE SET NULL,
    post_id uuid REFERENCES public.posts(id) ON DELETE SET NULL,
    strike_type text NOT NULL CHECK (strike_type IN ('advertencia', 'silenciamiento_24h', 'silenciamiento_7d', 'suspension_total')),
    reason text NOT NULL,
    issued_by uuid NOT NULL REFERENCES auth.users(id),
    expires_at timestamptz,                  -- NULL para sanciones permanentes
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_user_strikes_active ON public.user_forum_strikes(user_id) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_user_strikes_created ON public.user_forum_strikes(created_at DESC);

ALTER TABLE public.user_forum_strikes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Staff can read forum strikes" ON public.user_forum_strikes;
CREATE POLICY "Staff can read forum strikes"
    ON public.user_forum_strikes
    FOR SELECT
    TO authenticated
    USING (
        public.is_pemtree_admin(auth.uid()) OR 
        public.is_pemtree_moderator(auth.uid())
    );

DROP POLICY IF EXISTS "Staff can manage forum strikes" ON public.user_forum_strikes;
CREATE POLICY "Staff can manage forum strikes"
    ON public.user_forum_strikes
    FOR ALL
    TO authenticated
    USING (
        public.is_pemtree_admin(auth.uid()) OR 
        public.is_pemtree_moderator(auth.uid())
    )
    WITH CHECK (
        public.is_pemtree_admin(auth.uid()) OR 
        public.is_pemtree_moderator(auth.uid())
    );

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.user_forum_strikes TO authenticated;

-- ----------------------------------------------------------------------------
-- 4. Función de Normalización Lingüística Anti-Evasión (Leetspeak + Diacríticos)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_normalize_profanity_text(p_text text)
RETURNS text AS $$
DECLARE
    v_norm text;
BEGIN
    IF p_text IS NULL OR length(trim(p_text)) = 0 THEN
        RETURN '';
    END IF;

    -- 1. Minúsculas
    v_norm := lower(p_text);

    -- 2. Desacentuación si unaccent existe, o reemplazos canónicos
    BEGIN
        v_norm := unaccent(v_norm);
    EXCEPTION WHEN undefined_function THEN
        v_norm := replace(v_norm, 'á', 'a');
        v_norm := replace(v_norm, 'é', 'e');
        v_norm := replace(v_norm, 'í', 'i');
        v_norm := replace(v_norm, 'ó', 'o');
        v_norm := replace(v_norm, 'ú', 'u');
        v_norm := replace(v_norm, 'ü', 'u');
    END;

    -- 3. Decodificación de caracteres Leetspeak y sustituciones comunes
    v_norm := replace(v_norm, '@', 'a');
    v_norm := replace(v_norm, '4', 'a');
    v_norm := replace(v_norm, '3', 'e');
    v_norm := replace(v_norm, '1', 'i');
    v_norm := replace(v_norm, '!', 'i');
    v_norm := replace(v_norm, '|', 'i');
    v_norm := replace(v_norm, '0', 'o');
    v_norm := replace(v_norm, '5', 's');
    v_norm := replace(v_norm, '$', 's');
    v_norm := replace(v_norm, '7', 't');

    -- 4. Colapso de caracteres repetidos consecutivos (ej: 'puuuuuta' -> 'puta', 'ceroteee' -> 'cerote')
    v_norm := regexp_replace(v_norm, '([a-z0-9])\1{2,}', '\1', 'g');

    RETURN v_norm;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ----------------------------------------------------------------------------
-- 5. Trigger en PostgreSQL para Filtrado Automático Previo al INSERT / UPDATE
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_filter_comment_profanity()
RETURNS TRIGGER AS $$
DECLARE
    v_clean_text text;
    v_found_terms text[] := '{}';
    v_max_severity integer := 0;
    v_highest_action text := 'none';
    v_term_record record;
    v_pattern text;
    v_masked_term text;
BEGIN
    IF NEW.content IS NULL OR length(trim(NEW.content)) = 0 THEN
        RETURN NEW;
    END IF;

    -- 1. Normalizar texto del comentario
    v_clean_text := public.fn_normalize_profanity_text(NEW.content);

    -- 2. Contrastar contra el diccionario dinámico activo
    FOR v_term_record IN 
        SELECT term, normalized_term, severity_level, action_type, match_mode 
        FROM public.profanity_dictionary 
        WHERE is_active = true
        ORDER BY severity_level DESC
    LOOP
        IF v_term_record.match_mode = 'contains' THEN
            v_pattern := v_term_record.normalized_term;
        ELSIF v_term_record.match_mode = 'regex' THEN
            v_pattern := v_term_record.normalized_term;
        ELSE
            -- Coincidencia exacta por palabra delimitada
            v_pattern := '\m' || v_term_record.normalized_term || '\M';
        END IF;

        IF v_clean_text ~* v_pattern THEN
            IF NOT (v_term_record.term = ANY(v_found_terms)) THEN
                v_found_terms := array_append(v_found_terms, v_term_record.term);
            END IF;

            IF v_term_record.severity_level > v_max_severity THEN
                v_max_severity := v_term_record.severity_level;
                v_highest_action := v_term_record.action_type;
            END IF;
        END IF;
    END LOOP;

    -- 3. Aplicar reglas de severidad
    IF v_max_severity = 3 THEN
        -- Severidad Alta: Bloqueo preventivo
        NEW.moderation_status := 2; -- Oculto/Bloqueado
        NEW.is_flagged := true;
        NEW.toxicity_score := 0.95;
        NEW.flag_reason := 'Bloqueo automático por lenguaje de alta toxicidad / infracción grave: ' || array_to_string(v_found_terms, ', ');
        NEW.profanity_matches := v_found_terms;
        NEW.auto_moderated := true;

    ELSIF v_max_severity = 2 THEN
        -- Severidad Media: Enviar a cola de revisión
        NEW.moderation_status := 3; -- Requiere revisión humana
        NEW.is_flagged := true;
        NEW.toxicity_score := 0.75;
        NEW.flag_reason := 'Posible lenguaje inapropiado detectado: ' || array_to_string(v_found_terms, ', ');
        NEW.profanity_matches := v_found_terms;
        NEW.auto_moderated := true;

    ELSIF v_max_severity = 1 THEN
        -- Severidad Baja: Enmascarar palabras malsonantes en el contenido
        NEW.profanity_matches := v_found_terms;
        NEW.toxicity_score := 0.35;
        NEW.auto_moderated := true;

        FOREACH v_term_record.term IN ARRAY v_found_terms LOOP
            IF length(v_term_record.term) > 2 THEN
                v_masked_term := substring(v_term_record.term, 1, 1) || repeat('*', length(v_term_record.term) - 2) || substring(v_term_record.term, length(v_term_record.term), 1);
            ELSE
                v_masked_term := repeat('*', length(v_term_record.term));
            END IF;

            NEW.content := regexp_replace(
                NEW.content, 
                '\m' || v_term_record.term || '\M', 
                v_masked_term, 
                'gi'
            );
        END LOOP;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_filter_comment_profanity ON public.comments;
CREATE TRIGGER trg_filter_comment_profanity
    BEFORE INSERT OR UPDATE OF content ON public.comments
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_filter_comment_profanity();

-- ----------------------------------------------------------------------------
-- 6. RPC: Simulador / Probador en Vivo del Filtro Antipalabrotas
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.test_profanity_filter(p_text text)
RETURNS jsonb AS $$
DECLARE
    v_clean_text text;
    v_found_terms text[] := '{}';
    v_found_details jsonb := '[]'::jsonb;
    v_max_severity integer := 0;
    v_highest_action text := 'none';
    v_term_record record;
    v_pattern text;
    v_masked_text text := p_text;
    v_masked_term text;
BEGIN
    IF p_text IS NULL OR length(trim(p_text)) = 0 THEN
        RETURN jsonb_build_object(
            'is_flagged', false,
            'max_severity', 0,
            'action_type', 'none',
            'matches', '[]'::jsonb,
            'masked_text', '',
            'normalized_text', ''
        );
    END IF;

    v_clean_text := public.fn_normalize_profanity_text(p_text);

    FOR v_term_record IN 
        SELECT id, term, normalized_term, category, severity_level, action_type, match_mode 
        FROM public.profanity_dictionary 
        WHERE is_active = true
        ORDER BY severity_level DESC
    LOOP
        IF v_term_record.match_mode = 'contains' THEN
            v_pattern := v_term_record.normalized_term;
        ELSIF v_term_record.match_mode = 'regex' THEN
            v_pattern := v_term_record.normalized_term;
        ELSE
            v_pattern := '\m' || v_term_record.normalized_term || '\M';
        END IF;

        IF v_clean_text ~* v_pattern THEN
            IF NOT (v_term_record.term = ANY(v_found_terms)) THEN
                v_found_terms := array_append(v_found_terms, v_term_record.term);
                v_found_details := v_found_details || jsonb_build_object(
                    'term', v_term_record.term,
                    'category', v_term_record.category,
                    'severity_level', v_term_record.severity_level,
                    'action_type', v_term_record.action_type
                );
            END IF;

            IF v_term_record.severity_level > v_max_severity THEN
                v_max_severity := v_term_record.severity_level;
                v_highest_action := v_term_record.action_type;
            END IF;

            -- Generar versión enmascarada
            IF length(v_term_record.term) > 2 THEN
                v_masked_term := substring(v_term_record.term, 1, 1) || repeat('*', length(v_term_record.term) - 2) || substring(v_term_record.term, length(v_term_record.term), 1);
            ELSE
                v_masked_term := repeat('*', length(v_term_record.term));
            END IF;

            v_masked_text := regexp_replace(
                v_masked_text,
                '\m' || v_term_record.term || '\M',
                v_masked_term,
                'gi'
            );
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'is_flagged', v_max_severity >= 2,
        'max_severity', v_max_severity,
        'action_type', CASE 
            WHEN v_max_severity = 3 THEN 'block'
            WHEN v_max_severity = 2 THEN 'flag'
            WHEN v_max_severity = 1 THEN 'mask'
            ELSE 'none'
        END,
        'matches', v_found_details,
        'matched_terms', to_jsonb(v_found_terms),
        'masked_text', v_masked_text,
        'normalized_text', v_clean_text
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.test_profanity_filter(text) TO authenticated;

-- ----------------------------------------------------------------------------
-- 7. Función Definitiva de Borrado de Comentarios: `admin_hard_delete_comment`
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_hard_delete_comment(
    p_comment_id uuid,
    p_justificacion text
)
RETURNS jsonb AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_has_replies boolean := false;
    v_comment_row record;
BEGIN
    -- 1. Validar que el ejecutor sea Administrador Global
    IF NOT public.is_pemtree_admin(v_user_id) THEN
        RAISE EXCEPTION 'Permiso denegado: Únicamente los Administradores Globales pueden ejecutar la eliminación definitiva de comentarios.';
    END IF;

    IF p_justificacion IS NULL OR trim(p_justificacion) = '' THEN
        RAISE EXCEPTION 'La justificación es obligatoria para registrar la pista de auditoría del borrado.';
    END IF;

    SELECT * INTO v_comment_row FROM public.comments WHERE id = p_comment_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El comentario especificado no existe o ya fue eliminado.';
    END IF;

    -- 2. Comprobar si existen respuestas secundarias anidadas a este comentario
    SELECT EXISTS (SELECT 1 FROM public.comments WHERE parent_id = p_comment_id) INTO v_has_replies;

    -- 3. Registrar en bitácora de auditoría inmutable
    INSERT INTO public.moderation_audit_log (
        moderator_id,
        entity_table,
        entity_id,
        justification,
        is_automated,
        moderation_label
    ) VALUES (
        v_user_id,
        'comments',
        p_comment_id,
        trim(p_justificacion) || ' [Borrado definitivo ejecutado por Administrador Global]',
        false,
        'deleted_hard'
    );

    -- 4. Ejecutar borrado o preservación tombstone
    IF v_has_replies THEN
        -- Preservar el árbol jerárquico de respuestas (Tombstone Purge)
        UPDATE public.comments
        SET content = '[Comentario eliminado permanentemente por el Administrador]',
            gif_url = NULL,
            is_deleted = true,
            deleted_at = now(),
            deleted_by = v_user_id,
            moderation_status = 2,
            moderation_reason = trim(p_justificacion),
            is_flagged = false
        WHERE id = p_comment_id;

        RETURN jsonb_build_object(
            'success', true,
            'mode', 'tombstone_preserved',
            'message', 'El comentario tiene respuestas asociadas. Se purgó el contenido y se preservó el árbol jerárquico.'
        );
    ELSE
        -- Borrado físico limpio y decremento de contador en posts
        DELETE FROM public.comments WHERE id = p_comment_id;

        UPDATE public.posts
        SET comment_count = GREATEST(0, comment_count - 1)
        WHERE id = v_comment_row.post_id;

        RETURN jsonb_build_object(
            'success', true,
            'mode', 'hard_deleted',
            'message', 'Comentario eliminado de forma definitiva de la base de datos.'
        );
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.admin_hard_delete_comment(uuid, text) TO authenticated;

-- ----------------------------------------------------------------------------
-- 8. RPC: Aplicar Sanción / Strike a Estudiante desde Foro
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_issue_forum_strike(
    p_user_id uuid,
    p_strike_type text,
    p_reason text,
    p_comment_id uuid DEFAULT NULL,
    p_post_id uuid DEFAULT NULL
)
RETURNS jsonb AS $$
DECLARE
    v_admin_id uuid := auth.uid();
    v_expires_at timestamptz := NULL;
    v_new_strike_id uuid;
BEGIN
    IF NOT (public.is_pemtree_admin(v_admin_id) OR public.is_pemtree_moderator(v_admin_id)) THEN
        RAISE EXCEPTION 'Permiso denegado: Se requiere rol de moderador o administrador para emitir sanciones.';
    END IF;

    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RAISE EXCEPTION 'La razón de la sanción es obligatoria.';
    END IF;

    IF p_strike_type = 'silenciamiento_24h' THEN
        v_expires_at := now() + interval '24 hours';
    ELSIF p_strike_type = 'silenciamiento_7d' THEN
        v_expires_at := now() + interval '7 days';
    ELSIF p_strike_type = 'suspension_total' THEN
        v_expires_at := NULL;
    ELSIF p_strike_type = 'advertencia' THEN
        v_expires_at := now() + interval '30 days';
    ELSE
        RAISE EXCEPTION 'Tipo de sanción no válido: %', p_strike_type;
    END IF;

    INSERT INTO public.user_forum_strikes (
        user_id,
        comment_id,
        post_id,
        strike_type,
        reason,
        issued_by,
        expires_at,
        is_active
    ) VALUES (
        p_user_id,
        p_comment_id,
        p_post_id,
        p_strike_type,
        trim(p_reason),
        v_admin_id,
        v_expires_at,
        true
    ) RETURNING id INTO v_new_strike_id;

    -- Registrar en auditoría
    INSERT INTO public.moderation_audit_log (
        moderator_id,
        entity_table,
        entity_id,
        justification,
        is_automated,
        moderation_label
    ) VALUES (
        v_admin_id,
        'user_forum_strikes',
        v_new_strike_id,
        'Sanción (' || p_strike_type || ') emitida al estudiante: ' || trim(p_reason),
        false,
        'strike_issued'
    );

    RETURN jsonb_build_object(
        'success', true,
        'strike_id', v_new_strike_id,
        'strike_type', p_strike_type,
        'expires_at', v_expires_at
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.admin_issue_forum_strike(uuid, text, text, uuid, uuid) TO authenticated;

-- ----------------------------------------------------------------------------
-- 9. Actualización a `eliminar_contenido_moderado` para enrutar comments
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.eliminar_contenido_moderado(p_tabla text, p_item_id uuid, p_justificacion text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_user_id uuid := auth.uid();
    v_owner_id uuid;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No estás autenticado en el sistema.';
    END IF;

    IF NOT public.is_pemtree_admin(v_user_id) THEN
        RAISE EXCEPTION 'Permiso denegado: Solo el administrador de PEMTREE puede eliminar contenido de forma definitiva.';
    END IF;

    IF p_tabla = 'comments' THEN
        -- Delegar a admin_hard_delete_comment para garantizar integridad de respuestas y auditoría
        PERFORM public.admin_hard_delete_comment(p_item_id, COALESCE(NULLIF(TRIM(p_justificacion), ''), 'Eliminación definitiva por administrador'));
        RETURN true;
    ELSIF p_tabla = 'whatsapp_groups' THEN
        SELECT user_id INTO v_owner_id FROM public.whatsapp_groups WHERE id = p_item_id;
    ELSIF p_tabla = 'student_groups' THEN
        SELECT user_id INTO v_owner_id FROM public.student_groups WHERE id = p_item_id;
    ELSIF p_tabla = 'posts' THEN
        SELECT user_id INTO v_owner_id FROM public.posts WHERE id = p_item_id;
    ELSIF p_tabla = 'marketplace_items' THEN
        SELECT user_id INTO v_owner_id FROM public.marketplace_items WHERE id = p_item_id;
    ELSE
        RAISE EXCEPTION 'Tabla (%) no válida para moderación.', p_tabla;
    END IF;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El registro ya no existe o fue eliminado previamente en la base de datos.';
    END IF;

    INSERT INTO public.moderation_audit_log (moderator_id, entity_table, entity_id, justification, is_automated, moderation_label)
    VALUES (v_user_id, p_tabla, p_item_id,
            COALESCE(NULLIF(TRIM(p_justificacion), ''), 'Eliminación definitiva por administrador'),
            false, 'deleted');

    IF p_tabla = 'whatsapp_groups' THEN
        DELETE FROM public.whatsapp_groups WHERE id = p_item_id;
    ELSIF p_tabla = 'student_groups' THEN
        DELETE FROM public.student_groups WHERE id = p_item_id;
    ELSIF p_tabla = 'posts' THEN
        DELETE FROM public.posts WHERE id = p_item_id;
    ELSIF p_tabla = 'marketplace_items' THEN
        DELETE FROM public.marketplace_items WHERE id = p_item_id;
    END IF;

    RETURN true;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 10. Datos Semilla: Diccionario Inicial Calibrado para la Comunidad USAC
-- ----------------------------------------------------------------------------
INSERT INTO public.profanity_dictionary (term, normalized_term, category, severity_level, action_type, match_mode)
VALUES
    -- Severidad 3: Ataques graves, discriminación, acoso y fraude académico (Bloqueo Preventivo)
    ('hdp', 'hdp', 'insulto_grave', 3, 'block', 'exact'),
    ('hijo de puta', 'hijo de puta', 'insulto_grave', 3, 'block', 'contains'),
    ('malparido', 'malparido', 'insulto_grave', 3, 'block', 'contains'),
    ('maricon', 'maricon', 'discriminacion', 3, 'block', 'exact'),
    ('hueco de mierda', 'hueco de mierda', 'discriminacion', 3, 'block', 'contains'),
    ('indio de mierda', 'indio de mierda', 'discriminacion', 3, 'block', 'contains'),
    ('chucho desgraciado', 'chucho desgraciado', 'insulto_grave', 3, 'block', 'contains'),
    ('compro tareas', 'compro tareas', 'spam_fraude', 3, 'block', 'contains'),
    ('hago parciales', 'hago parciales', 'spam_fraude', 3, 'block', 'contains'),
    ('hackeo notas', 'hackeo notas', 'spam_fraude', 3, 'block', 'contains'),
    ('vendo examenes', 'vendo examenes', 'spam_fraude', 3, 'block', 'contains'),
    ('fotos intimas', 'fotos intimas', 'acoso_sexual', 3, 'block', 'contains'),
    ('pack de', 'pack de', 'acoso_sexual', 3, 'block', 'contains'),

    -- Severidad 2: Insultos comunes, agresiones entre compañeros (Requiere Revisión)
    ('pendejo', 'pendejo', 'insulto_grave', 2, 'flag', 'exact'),
    ('idiota', 'idiota', 'insulto_grave', 2, 'flag', 'exact'),
    ('estupido', 'estupido', 'insulto_grave', 2, 'flag', 'exact'),
    ('imbecil', 'imbecil', 'insulto_grave', 2, 'flag', 'exact'),
    ('maldito', 'maldito', 'insulto_grave', 2, 'flag', 'exact'),
    ('culero', 'culero', 'vulgaridad_comun', 2, 'flag', 'exact'),
    ('t.me/', 't.me/', 'spam_fraude', 2, 'flag', 'contains'),
    ('wa.me/', 'wa.me/', 'spam_fraude', 2, 'flag', 'contains'),

    -- Severidad 1: Vulgaridad y modismos guatemaltecos comunes (Enmascaramiento)
    ('cerote', 'cerote', 'vulgaridad_comun', 1, 'mask', 'exact'),
    ('pisado', 'pisado', 'vulgaridad_comun', 1, 'mask', 'exact'),
    ('mierda', 'mierda', 'vulgaridad_comun', 1, 'mask', 'exact'),
    ('puta', 'puta', 'vulgaridad_comun', 1, 'mask', 'exact'),
    ('huevon', 'huevon', 'vulgaridad_comun', 1, 'mask', 'exact'),
    ('chingados', 'chingados', 'vulgaridad_comun', 1, 'mask', 'exact'),
    ('carajo', 'carajo', 'vulgaridad_comun', 1, 'mask', 'exact')
ON CONFLICT (term) DO UPDATE SET
    normalized_term = EXCLUDED.normalized_term,
    category = EXCLUDED.category,
    severity_level = EXCLUDED.severity_level,
    action_type = EXCLUDED.action_type,
    match_mode = EXCLUDED.match_mode,
    is_active = true,
    updated_at = timezone('utc'::text, now());
