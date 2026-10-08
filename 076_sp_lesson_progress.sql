
-- Progreso por leccion: sp_StartLesson y sp_CompleteLesson
-- Registran el momento exacto en que el estudiante inicia y termina cada
-- leccion (lesson_progress). Estos tiempos alimentan:
--   - la deteccion de fraude por tiempo implausible (sp_IssueCertificate),
--   - las horas de estudio acumuladas del reporte de actividad (Fase 4).
-- sp_CompleteModule exige que todas las lecciones del modulo esten
-- completadas antes de marcar el modulo.
--
-- Ambos SPs son idempotentes, porque el mismo estudiante puede reportar la
-- misma leccion desde dos dispositivos a la vez:
--   - Iniciar dos veces conserva el started_at original (la primera vez).
--   - Completar dos veces conserva el completed_at original y avisa por
--     @already_completed, en lugar de sobrescribir el momento del avance.
-- Pueden usarse con la inscripcion activa o completada (repasar contenido);
-- una inscripcion reembolsada pierde el acceso al contenido.

-- sp_StartLesson
-- Concurrencia: el INSERT ... WHERE NOT EXISTS puede competir con otro
-- dispositivo; si ambos pasan la comprobacion, UQ_lp_enrollment_lesson rechaza
-- el segundo INSERT (2601/2627) y se trata como "ya iniciada".
CREATE OR ALTER PROCEDURE dbo.sp_StartLesson
    @enrollment_id INT,
    @student_id    INT,
    @lesson_id     INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM enrollments WHERE id = @enrollment_id AND student_id = @student_id)
        THROW 61001, 'La inscripcion no existe o no pertenece a este estudiante.', 1;

    IF NOT EXISTS (SELECT 1 FROM enrollments WHERE id = @enrollment_id AND status IN ('active', 'completed'))
        THROW 61002, 'La inscripcion fue reembolsada; ya no tiene acceso al contenido.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM lessons l
        JOIN modules m     ON m.id = l.module_id
        JOIN enrollments e ON e.course_id = m.course_id
        WHERE l.id = @lesson_id AND e.id = @enrollment_id
    )
        THROW 61003, 'La leccion no existe o no pertenece al curso de esta inscripcion.', 1;

    BEGIN TRY
        INSERT INTO lesson_progress (enrollment_id, lesson_id, started_at, completed_at, version)
        SELECT @enrollment_id, @lesson_id, GETDATE(), NULL, 0
        WHERE NOT EXISTS (
            SELECT 1 FROM lesson_progress WHERE enrollment_id = @enrollment_id AND lesson_id = @lesson_id
        );
    END TRY
    BEGIN CATCH
        -- Otro dispositivo la inicio en el mismo instante: ya esta registrada.
        IF ERROR_NUMBER() IN (2601, 2627)
            RETURN;

        THROW;
    END CATCH
END;

-- sp_CompleteLesson
-- Concurrencia: UPDATE condicionado a completed_at IS NULL. Si dos
-- dispositivos completan la misma leccion a la vez, el bloqueo de fila hace
-- que el segundo espere y, al reevaluar la condicion, no encuentre la fila:
-- @@ROWCOUNT = 0 y se informa @already_completed = 1 sin sobrescribir nada.
CREATE OR ALTER PROCEDURE dbo.sp_CompleteLesson
    @enrollment_id     INT,
    @student_id        INT,
    @lesson_id         INT,
    @already_completed BIT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM enrollments WHERE id = @enrollment_id AND student_id = @student_id)
        THROW 61001, 'La inscripcion no existe o no pertenece a este estudiante.', 1;

    IF NOT EXISTS (SELECT 1 FROM enrollments WHERE id = @enrollment_id AND status IN ('active', 'completed'))
        THROW 61002, 'La inscripcion fue reembolsada; ya no tiene acceso al contenido.', 1;

    SET @already_completed = 0;

    UPDATE lesson_progress
        SET completed_at = GETDATE(),
            version      = version + 1
    WHERE enrollment_id = @enrollment_id
      AND lesson_id     = @lesson_id
      AND completed_at IS NULL;

    IF @@ROWCOUNT = 0
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM lesson_progress WHERE enrollment_id = @enrollment_id AND lesson_id = @lesson_id)
            THROW 61004, 'Debe iniciar la leccion antes de marcarla como completada.', 1;

        SET @already_completed = 1;
    END
END
