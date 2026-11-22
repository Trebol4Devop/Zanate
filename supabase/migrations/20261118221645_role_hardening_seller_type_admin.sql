CREATE OR REPLACE FUNCTION public.enforce_seller_admin_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_old_plan     text;
    v_old_expires  timestamptz;
    v_old_ver      text;
    v_old_type     text;
    v_exists       boolean := false;
BEGIN
    IF auth.uid() IS NULL OR public.is_pemtree_admin(auth.uid()) THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        SELECT sp.plan_id, sp.plan_expires_at, sp.verification_status, sp.seller_type
        INTO v_old_plan, v_old_expires, v_old_ver, v_old_type
        FROM public.seller_profiles sp
        WHERE sp.user_id = NEW.user_id;
        v_exists := FOUND;

        IF v_exists THEN
            IF NEW.plan_id IS DISTINCT FROM v_old_plan
               OR NEW.plan_expires_at IS DISTINCT FROM v_old_expires THEN
                RAISE EXCEPTION 'Solo un administrador puede cambiar el plan o la vigencia del vendedor' USING ERRCODE = '42501';
            END IF;
            IF NEW.seller_type IS DISTINCT FROM v_old_type THEN
                RAISE EXCEPTION 'Solo un administrador puede cambiar el tipo de vendedor' USING ERRCODE = '42501';
            END IF;
            IF NEW.verification_status = 'approved'
               AND NEW.verification_status IS DISTINCT FROM v_old_ver THEN
                RAISE EXCEPTION 'Solo un administrador puede aprobar la verificación de un vendedor' USING ERRCODE = '42501';
            END IF;
            RETURN NEW;
        END IF;

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
    IF NEW.seller_type IS DISTINCT FROM OLD.seller_type THEN
        RAISE EXCEPTION 'Solo un administrador puede cambiar el tipo de vendedor' USING ERRCODE = '42501';
    END IF;
    IF NEW.verification_status = 'approved'
       AND NEW.verification_status IS DISTINCT FROM OLD.verification_status THEN
        RAISE EXCEPTION 'Solo un administrador puede aprobar la verificación de un vendedor' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$function$;
