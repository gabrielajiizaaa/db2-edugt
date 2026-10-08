
-- fn_ProgressHistory
-- Historial de progreso de una inscripcion: una fila por leccion del curso con
-- el momento exacto en que se inicio y completo, el tiempo invertido y el
-- estado del modulo al que pertenece. Las lecciones aun no iniciadas aparecen
-- con fechas NULL, para ver el avance completo del curso.
--
-- Funcion con valores de tabla en linea (inline TVF): el optimizador la
-- expande como una vista parametrizada, por lo que puede usarse en JOINs y
-- en los reportes de la Fase 4 sin el costo de una funcion multi-statement.
--
-- Uso: SELECT * FROM dbo.fn_ProgressHistory(@enrollment_id) ORDER BY module_order, lesson_order;

CREATE OR ALTER FUNCTION dbo.fn_ProgressHistory (@enrollment_id INT)
RETURNS TABLE
AS
RETURN
    SELECT
        m.order_index         AS module_order,
        m.title               AS module_title,
        ISNULL(mp.completed, 0) AS module_completed,
        mp.completed_at       AS module_completed_at,
        l.order_index         AS lesson_order,
        l.title               AS lesson_title,
        l.duration_min        AS lesson_duration_min,
        lp.started_at         AS lesson_started_at,
        lp.completed_at       AS lesson_completed_at,
        CAST(DATEDIFF(SECOND, lp.started_at, lp.completed_at) / 60.0 AS DECIMAL(10,2)) AS minutes_spent
    FROM enrollments e
    JOIN modules m               ON m.course_id = e.course_id
    JOIN lessons l               ON l.module_id = m.id
    LEFT JOIN module_progress mp ON mp.enrollment_id = e.id AND mp.module_id = m.id
    LEFT JOIN lesson_progress lp ON lp.enrollment_id = e.id AND lp.lesson_id = l.id
    WHERE e.id = @enrollment_id;
