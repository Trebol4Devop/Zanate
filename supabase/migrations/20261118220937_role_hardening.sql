-- ============================================================================
-- PEMTREE Admin · Endurecimiento de roles (moderador vs administrador)
-- Fecha: 2026-11-18
-- ============================================================================

-- 1) Retención legal: solo administradores
CREATE OR REPLACE FUNCTION public.enforce_legal_hold_admin_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
    IF NEW.is_legal_hold IS DISTINCT FROM OLD.is_legal_hold
       AND auth.uid() IS NOT NULL
       AND NOT public.is_pemtree_admin(auth.uid()) THEN
        RAISE EXCEPTION 'Solo un administrador puede modificar la retención legal'
            USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_legal_hold_admin_only_posts ON public.posts;
CREATE TRIGGER trg_legal_hold_admin_only_posts BEFORE UPDATE ON public.posts FOR EACH ROW EXECUTE FUNCTION public.enforce_legal_hold_admin_only();
DROP TRIGGER IF EXISTS trg_legal_hold_admin_only_comments ON public.comments;
CREATE TRIGGER trg_legal_hold_admin_only_comments BEFORE UPDATE ON public.comments FOR EACH ROW EXECUTE FUNCTION public.enforce_legal_hold_admin_only();
DROP TRIGGER IF EXISTS trg_legal_hold_admin_only_student_groups ON public.student_groups;
CREATE TRIGGER trg_legal_hold_admin_only_student_groups BEFORE UPDATE ON public.student_groups FOR EACH ROW EXECUTE FUNCTION public.enforce_legal_hold_admin_only();
DROP TRIGGER IF EXISTS trg_legal_hold_admin_only_marketplace_items ON public.marketplace_items;
CREATE TRIGGER trg_legal_hold_admin_only_marketplace_items BEFORE UPDATE ON public.marketplace_items FOR EACH ROW EXECUTE FUNCTION public.enforce_legal_hold_admin_only();
DROP TRIGGER IF EXISTS trg_legal_hold_admin_only_seccion_reviews ON public.seccion_reviews;
CREATE TRIGGER trg_legal_hold_admin_only_seccion_reviews BEFORE UPDATE ON public.seccion_reviews FOR EACH ROW EXECUTE FUNCTION public.enforce_legal_hold_admin_only();

REVOKE UPDATE (is_legal_hold) ON public.posts FROM authenticated;
REVOKE UPDATE (is_legal_hold) ON public.comments FROM authenticated;
REVOKE UPDATE (is_legal_hold) ON public.student_groups FROM authenticated;
REVOKE UPDATE (is_legal_hold) ON public.marketplace_items FROM authenticated;
REVOKE UPDATE (is_legal_hold) ON public.seccion_reviews FROM authenticated;

-- 2) Reputación: ningún no-admin puede bajar más de 0.5 puntos
CREATE OR REPLACE FUNCTION public.enforce_reputation_delta_admin_only()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
    IF NEW.reputation_score IS DISTINCT FROM OLD.reputation_score
       AND NEW.reputation_score < (OLD.reputation_score - 0.5)
       AND auth.uid() IS NOT NULL
       AND NOT public.is_pemtree_admin(auth.uid()) THEN
        RAISE EXCEPTION 'Solo un administrador puede aplicar sanciones de reputación graves' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS trg_profiles_reputation_admin_only ON public.profiles;
CREATE TRIGGER trg_profiles_reputation_admin_only BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.enforce_reputation_delta_admin_only();

-- 3) Suspensión total de foro: solo admin
CREATE OR REPLACE FUNCTION public.enforce_suspension_admin_only()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
    IF NEW.strike_type = 'suspension_total'
       AND auth.uid() IS NOT NULL
       AND NOT public.is_pemtree_admin(auth.uid()) THEN
        RAISE EXCEPTION 'Solo un administrador puede aplicar una suspensión total' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS trg_user_forum_strikes_suspension_admin_only ON public.user_forum_strikes;
CREATE TRIGGER trg_user_forum_strikes_suspension_admin_only BEFORE INSERT ON public.user_forum_strikes FOR EACH ROW EXECUTE FUNCTION public.enforce_suspension_admin_only();

-- 4) Vendedores: plan/vigencia y aprobación de verificación solo admin
CREATE OR REPLACE FUNCTION public.enforce_seller_admin_fields()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
    IF auth.uid() IS NULL OR public.is_pemtree_admin(auth.uid()) THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF auth.uid() IS DISTINCT FROM NEW.user_id THEN
            RAISE EXCEPTION 'Solo un administrador puede crear perfiles de vendedor para otros usuarios' USING ERRCODE = '42501';
        END IF;
        IF NEW.plan_id IS DISTINCT FROM 'free'
           OR NEW.seller_type IS DISTINCT FROM 'student'
           OR NEW.verification_status IS DISTINCT FROM 'pending' THEN
            RAISE EXCEPTION 'Solo un administrador puede dar de alta un comercio o asignar un plan' USING ERRCODE = '42501';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.plan_id IS DISTINCT FROM OLD.plan_id
       OR NEW.plan_expires_at IS DISTINCT FROM OLD.plan_expires_at THEN
        RAISE EXCEPTION 'Solo un administrador puede cambiar el plan o la vigencia del vendedor' USING ERRCODE = '42501';
    END IF;

    IF NEW.verification_status = 'approved'
       AND NEW.verification_status IS DISTINCT FROM OLD.verification_status THEN
        RAISE EXCEPTION 'Solo un administrador puede aprobar la verificación de un vendedor' USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS trg_seller_admin_fields ON public.seller_profiles;
CREATE TRIGGER trg_seller_admin_fields BEFORE INSERT OR UPDATE ON public.seller_profiles FOR EACH ROW EXECUTE FUNCTION public.enforce_seller_admin_fields();

DROP POLICY IF EXISTS "Staff puede gestionar todos los perfiles de vendedor" ON public.seller_profiles;
DROP POLICY IF EXISTS "Admins can manage seller profiles" ON public.seller_profiles;
CREATE POLICY "Admins can manage seller profiles" ON public.seller_profiles FOR ALL TO authenticated USING (public.is_pemtree_admin(auth.uid())) WITH CHECK (public.is_pemtree_admin(auth.uid()));

-- 5) Patrocinadores: moderadores solo contacto/comercial
CREATE OR REPLACE FUNCTION public.guard_sponsor_request_workflow()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF auth.uid() IS NOT NULL AND auth.role() <> 'service_role' THEN
            IF NEW.user_id IS NULL THEN
                NEW.user_id := auth.uid();
            ELSIF NEW.user_id IS DISTINCT FROM auth.uid() THEN
                RAISE EXCEPTION 'No puedes crear una solicitud de patrocinio a nombre de otro usuario' USING ERRCODE = '42501';
            END IF;
            IF NEW.status IS DISTINCT FROM 'pending' THEN
                RAISE EXCEPTION 'Las solicitudes de patrocinio solo pueden crearse en estado pending' USING ERRCODE = '42501';
            END IF;
        END IF;
        RETURN NEW;
    END IF;

    IF auth.uid() IS NOT NULL AND auth.role() IS DISTINCT FROM 'service_role' AND NOT public.is_pemtree_admin(auth.uid()) THEN
        IF NEW.status IS DISTINCT FROM OLD.status OR NEW.user_id IS DISTINCT FROM OLD.user_id THEN
            RAISE EXCEPTION 'Only admins may review sponsor requests.' USING ERRCODE = '42501';
        END IF;
        IF NEW.plan_id IS DISTINCT FROM OLD.plan_id
           OR NEW.admin_note IS DISTINCT FROM OLD.admin_note
           OR NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by
           OR NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at THEN
            RAISE EXCEPTION 'Solo un administrador puede cambiar plan, nota administrativa o revisión de una solicitud de patrocinio' USING ERRCODE = '42501';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

-- 6) Strikes: gestión directa solo admin; lectura para staff
DROP POLICY IF EXISTS "Staff can manage forum strikes" ON public.user_forum_strikes;
DROP POLICY IF EXISTS "Admins can manage forum strikes" ON public.user_forum_strikes;
CREATE POLICY "Admins can manage forum strikes" ON public.user_forum_strikes FOR ALL TO authenticated USING (public.is_pemtree_admin(auth.uid())) WITH CHECK (public.is_pemtree_admin(auth.uid()));

-- 7) Reseñas campus: moderación por RPC auditada
CREATE OR REPLACE FUNCTION public.staff_set_campus_review_status(p_review_id uuid, p_status integer, p_reason text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
    v_uid uuid := auth.uid();
    v_reason text;
BEGIN
    IF v_uid IS NULL OR NOT (public.is_pemtree_admin(v_uid) OR public.is_pemtree_moderator(v_uid)) THEN
        RAISE EXCEPTION 'Permiso denegado: se requiere rol de moderador o administrador' USING ERRCODE = '42501';
    END IF;
    IF p_status NOT IN (1, 2, 3) THEN
        RAISE EXCEPTION 'Estado de moderación inválido: %', p_status USING ERRCODE = '22023';
    END IF;
    v_reason := COALESCE(NULLIF(btrim(COALESCE(p_reason, '')), ''), CASE p_status WHEN 1 THEN 'Aprobado por moderador' WHEN 2 THEN 'Ocultado por moderador' ELSE 'Pendiente de revisión' END);
    UPDATE public.campus_reviews SET moderation_status = p_status, moderation_reason = v_reason, updated_at = now() WHERE id = p_review_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La reseña % no existe', p_review_id USING ERRCODE = 'P0002';
    END IF;
    INSERT INTO public.moderation_audit_log (moderator_id, entity_table, entity_id, justification, is_automated, moderation_label)
    VALUES (v_uid, 'campus_reviews', p_review_id, v_reason, false, CASE p_status WHEN 1 THEN 'appropriate' WHEN 2 THEN 'inappropriate' ELSE 'review' END);
    RETURN true;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.staff_set_campus_review_status(uuid, integer, text) TO authenticated;

DROP POLICY IF EXISTS "Update own review or staff" ON public.campus_reviews;
DROP POLICY IF EXISTS "Update own review or admin" ON public.campus_reviews;
CREATE POLICY "Update own review or admin" ON public.campus_reviews FOR UPDATE TO authenticated USING ((auth.uid() = user_id) OR public.is_pemtree_admin(auth.uid())) WITH CHECK ((auth.uid() = user_id) OR public.is_pemtree_admin(auth.uid()));

-- 8) Storage: borrado de archivos de contenido solo admin
DROP POLICY IF EXISTS "Admins can delete content assets" ON storage.objects;
CREATE POLICY "Admins can delete content assets" ON storage.objects FOR DELETE TO authenticated USING (bucket_id = ANY (ARRAY['images', 'public', 's3', 'media', 'pemtree', 'marketplace']) AND public.is_pemtree_admin(auth.uid()));

-- 9) Retención legal: RPC explícitamente solo admin
CREATE OR REPLACE FUNCTION public.admin_toggle_legal_hold(p_table text, p_id uuid, p_value boolean)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
    v_uid uuid := auth.uid();
    v_updated boolean := false;
    v_justification text;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501';
    END IF;
    IF NOT public.is_pemtree_admin(v_uid) THEN
        RAISE EXCEPTION 'Permiso denegado: solo un administrador puede alternar la retención legal' USING ERRCODE = '42501';
    END IF;
    IF p_table NOT IN ('posts', 'comments', 'student_groups', 'marketplace_items', 'seccion_reviews') THEN
        RAISE EXCEPTION 'Tabla (%) no válida para retención legal.', p_table USING ERRCODE = '22023';
    END IF;
    IF p_table = 'posts' THEN
        UPDATE public.posts SET is_legal_hold = p_value, updated_at = now() WHERE id = p_id; v_updated := FOUND;
    ELSIF p_table = 'comments' THEN
        UPDATE public.comments SET is_legal_hold = p_value, updated_at = now() WHERE id = p_id; v_updated := FOUND;
    ELSIF p_table = 'student_groups' THEN
        UPDATE public.student_groups SET is_legal_hold = p_value, updated_at = now() WHERE id = p_id; v_updated := FOUND;
    ELSIF p_table = 'marketplace_items' THEN
        UPDATE public.marketplace_items SET is_legal_hold = p_value, updated_at = now() WHERE id = p_id; v_updated := FOUND;
    ELSIF p_table = 'seccion_reviews' THEN
        UPDATE public.seccion_reviews SET is_legal_hold = p_value, updated_at = now() WHERE id = p_id; v_updated := FOUND;
    END IF;
    IF NOT v_updated THEN
        RAISE EXCEPTION 'El registro ya no existe en la base de datos.' USING ERRCODE = 'P0002';
    END IF;
    v_justification := CASE WHEN p_value THEN 'Retención legal activada' ELSE 'Retención legal desactivada' END;
    INSERT INTO public.moderation_audit_log (moderator_id, entity_table, entity_id, justification, is_automated, moderation_label)
    VALUES (v_uid, p_table, p_id, v_justification, false, 'legal_hold');
    RETURN true;
END;
$function$;

-- 10) Marketplace: destacar/patrocinar solo admin
CREATE OR REPLACE FUNCTION public.admin_set_marketplace_item_state(
    p_item_id uuid,
    p_status text DEFAULT NULL::text,
    p_is_sponsored boolean DEFAULT NULL::boolean,
    p_sponsor_badge_text text DEFAULT NULL::text,
    p_note text DEFAULT NULL::text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
    v_actor uuid := auth.uid();
    v_old_status text;
    v_old_sponsored boolean;
    v_old_badge text;
    v_old_expires timestamptz;
    v_item_user uuid;
    v_legal_hold boolean;
    v_new_status text;
    v_new_sponsored boolean;
    v_new_badge text;
    v_new_expires timestamptz;
    v_item_plan public.marketplace_plans;
    v_claims text;
    v_sub text;
BEGIN
    IF NOT public.is_marketplace_staff(v_actor) THEN
        RAISE EXCEPTION 'Solo el personal de PEMTREE (administrador o moderador) puede cambiar el estado de una publicación' USING ERRCODE = '42501';
    END IF;
    IF NOT public.is_pemtree_admin(v_actor)
       AND (p_is_sponsored IS NOT NULL OR NULLIF(btrim(COALESCE(p_sponsor_badge_text, '')), '') IS NOT NULL) THEN
        RAISE EXCEPTION 'Solo un administrador puede destacar o patrocinar publicaciones' USING ERRCODE = '42501';
    END IF;

    SELECT mi.status, mi.is_sponsored, mi.sponsor_badge_text, mi.is_legal_hold, mi.expires_at, mi.user_id
    INTO v_old_status, v_old_sponsored, v_old_badge, v_legal_hold, v_old_expires, v_item_user
    FROM public.marketplace_items mi WHERE mi.id = p_item_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La publicación % no existe', p_item_id USING ERRCODE = 'P0002';
    END IF;
    IF v_legal_hold THEN
        RAISE EXCEPTION 'No se puede modificar un ítem con retención legal' USING ERRCODE = '23514';
    END IF;
    IF p_status IS NOT NULL AND p_status NOT IN ('available', 'reserved', 'sold', 'paused', 'archived') THEN
        RAISE EXCEPTION 'Estado % no permitido (válidos: available, reserved, sold, paused, archived)', p_status USING ERRCODE = '22023';
    END IF;

    IF p_sponsor_badge_text IS NULL THEN
        v_new_badge := v_old_badge;
    ELSE
        v_new_badge := NULLIF(btrim(p_sponsor_badge_text), '');
        IF v_new_badge IS NOT NULL AND length(v_new_badge) > 40 THEN
            RAISE EXCEPTION 'La insignia de patrocinio no puede superar los 40 caracteres' USING ERRCODE = '23514';
        END IF;
    END IF;

    v_new_status := COALESCE(p_status, v_old_status);
    v_new_sponsored := COALESCE(p_is_sponsored, v_old_sponsored);
    v_item_plan := public.get_effective_seller_plan(v_item_user);

    v_new_expires := CASE
        WHEN v_new_status IN ('available', 'reserved') AND v_item_plan.id = 'free' THEN
            CASE WHEN v_old_status NOT IN ('available', 'reserved') OR v_old_expires IS NULL OR v_old_expires <= now()
                 THEN now() + interval '14 days' ELSE v_old_expires END
        WHEN v_new_status IN ('available', 'reserved') THEN NULL
        ELSE v_old_expires
    END;

    IF v_new_status IS DISTINCT FROM v_old_status
       OR v_new_sponsored IS DISTINCT FROM v_old_sponsored
       OR v_new_badge IS DISTINCT FROM v_old_badge
       OR v_new_expires IS DISTINCT FROM v_old_expires THEN
        v_claims := current_setting('request.jwt.claims', true);
        v_sub := current_setting('request.jwt.claim.sub', true);
        PERFORM set_config('request.jwt.claims', '', true);
        PERFORM set_config('request.jwt.claim.sub', '', true);
        UPDATE public.marketplace_items
        SET status = v_new_status, is_sponsored = v_new_sponsored, sponsor_badge_text = v_new_badge,
            expires_at = v_new_expires, updated_at = now()
        WHERE id = p_item_id;
        PERFORM set_config('request.jwt.claims', COALESCE(v_claims, ''), true);
        PERFORM set_config('request.jwt.claim.sub', COALESCE(v_sub, ''), true);
    END IF;

    INSERT INTO public.marketplace_admin_audit (actor_id, action, target_type, target_id, details, note)
    VALUES (v_actor, 'item.state', 'item', p_item_id::text,
        jsonb_build_object('status_before', v_old_status, 'status_after', v_new_status,
            'is_sponsored_before', v_old_sponsored, 'is_sponsored_after', v_new_sponsored,
            'badge_before', v_old_badge, 'badge_after', v_new_badge,
            'expires_before', v_old_expires, 'expires_after', v_new_expires),
        p_note);

    RETURN jsonb_build_object('ok', true, 'id', p_item_id, 'status', v_new_status, 'is_sponsored', v_new_sponsored);
END;
$function$;