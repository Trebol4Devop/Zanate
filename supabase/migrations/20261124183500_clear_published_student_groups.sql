-- Limpia todos los grupos de estudio publicados y sus votos asociados.
-- El trigger de retención legal se mantiene activo: los grupos con
-- is_legal_hold = true no se pueden borrar.
DELETE FROM public.student_group_upvotes;
DELETE FROM public.student_groups;
