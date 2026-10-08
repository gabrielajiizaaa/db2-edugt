
-- sp_EnrollStudent
-- Inscribe a un estudiante en un curso, cobrando el precio vigente contra su
-- billetera virtual y ocupando un lugar de la cohorte si el curso es en vivo.
-- Todo ocurre en una sola transaccion: si cualquier paso falla no queda rastro
-- parcial (ni cobro, ni cupo ocupado, ni inscripcion).
--
-- Validaciones (enunciado, "Inscripcion, progreso y emision de certificados"):
--   - El curso existe y esta disponible (status = 'available').
--   - El estudiante no tiene ya una inscripcion activa en el curso.
--   - Aprobo (inscripcion 'completed') todos los cursos requisito previo.
--   - Si el curso tiene cohortes activas, debe elegir una; la cohorte debe
--     pertenecer al curso, estar activa y no haber terminado.
--   - Su billetera tiene saldo suficiente para el precio vigente.
--   - La cohorte tiene cupo en el momento exacto de la inscripcion.
--
-- Al confirmarse:
--   - Se descuenta el precio de la billetera y se registra el movimiento.
--   - La inscripcion queda con settlement_status = 'pending': es el ingreso
--     pendiente de liquidacion para el instructor (Fase 4).
--   - Se guarda la politica de reembolso vigente (snapshot) en la inscripcion.
--   - Se ocupa un lugar de la cohorte.
--
-- CONCURRENCIA (detalle en la documentacion tecnica, seccion de Fase 3):
--   Saldo: UPDATE atomico condicionado
--       UPDATE wallets SET balance = balance - @price ... WHERE balance >= @price
--     El UPDATE toma bloqueo exclusivo sobre la fila de la billetera; una
--     segunda operacion simultanea (otra inscripcion o un reembolso) espera y,
--     al continuar, evalua la condicion contra el saldo ya actualizado. Nunca
--     hay dos lecturas del mismo saldo. CK_wallets_balance (balance >= 0) es la
--     garantia final a nivel de motor.
--   Cupo: mismo patron sobre la cohorte
--       UPDATE cohorts SET occupied_slots = occupied_slots + 1
--       WHERE id = @cohort_id AND occupied_slots < max_capacity
--     Las solicitudes simultaneas por los ultimos lugares se forman en fila
--     sobre la fila de la cohorte: cada una ve el conteo real del momento, por
--     lo que no se sobrevende y tampoco se rechaza a nadie mientras haya lugar
--     (un control optimista por version si rechazaria solicitudes aun con cupo).
--     CK_cohorts_slots_max es la garantia final.
--   Doble inscripcion: UX_enrollments_active (indice unico filtrado) rechaza la
--     segunda inscripcion activa; el error 2601 revierte tambien el cobro.
--   Orden de bloqueo: billetera -> cohorte -> inscripcion. Cualquier SP que
--     toque las mismas filas (p.ej. el reembolso de Fase 4) debe respetar este
--     orden para no generar deadlocks.
--   Nivel de aislamiento: READ COMMITTED (por defecto). Los UPDATE atomicos ya
--     serializan los puntos de contencion; SERIALIZABLE solo agregaria bloqueos
--     de rango innecesarios sobre tablas calientes.

CREATE OR ALTER PROCEDURE dbo.sp_EnrollStudent
    @student_id        INT,
    @course_id         INT,
    @cohort_id         INT = NULL,
    @new_enrollment_id INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM users WHERE id = @student_id AND role = 'student' AND active = 1)
        THROW 60001, 'El estudiante no existe, no esta activo o no tiene rol student.', 1;

    DECLARE @price DECIMAL(10,2), @course_title VARCHAR(200);
    SELECT @price = price, @course_title = title
    FROM courses
    WHERE id = @course_id AND status = 'available';

    IF @price IS NULL
        THROW 60002, 'El curso no existe o no esta disponible para inscripcion.', 1;

    IF EXISTS (SELECT 1 FROM enrollments WHERE student_id = @student_id AND course_id = @course_id AND status = 'active')
        THROW 60003, 'El estudiante ya tiene una inscripcion activa en este curso.', 1;

    IF EXISTS (
        SELECT 1 FROM course_prerequisites cp
        WHERE cp.course_id = @course_id
          AND NOT EXISTS (
              SELECT 1 FROM enrollments e
              WHERE e.student_id = @student_id
                AND e.course_id = cp.prerequisite_id
                AND e.status = 'completed'
          )
    )
        THROW 60004, 'Requisito previo no aprobado: debe completar todos los cursos requisito antes de inscribirse.', 1;

    IF @cohort_id IS NULL AND EXISTS (SELECT 1 FROM cohorts WHERE course_id = @course_id AND active = 1)
        THROW 60005, 'Este curso se imparte en vivo: debe elegir una cohorte para inscribirse.', 1;

    IF @cohort_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM cohorts
        WHERE id = @cohort_id AND course_id = @course_id AND active = 1
          AND (ends_at IS NULL OR ends_at > GETDATE())
    )
        THROW 60006, 'La cohorte no existe, no pertenece al curso o ya no esta activa.', 1;

    -- Snapshot de la politica de reembolso vigente al momento de inscribirse.
    DECLARE @refund_policy_id INT = (SELECT id FROM refund_policies WHERE active = 1);
    IF @refund_policy_id IS NULL
        THROW 60007, 'No hay una politica de reembolso vigente. Contacte al administrador.', 1;

    IF NOT EXISTS (SELECT 1 FROM wallets WHERE user_id = @student_id)
        THROW 60008, 'El estudiante no tiene billetera virtual.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. Cobro atomico contra la billetera.
        DECLARE @wallet_id INT, @new_balance DECIMAL(12,2);
        UPDATE wallets
            SET balance      = balance - @price,
                version      = version + 1,
                @wallet_id   = id,
                @new_balance = balance - @price
        WHERE user_id = @student_id
          AND balance >= @price;

        IF @@ROWCOUNT = 0
            THROW 60009, 'Saldo insuficiente: la billetera no cubre el precio del curso.', 1;

        -- 2. Ocupar un lugar de la cohorte de forma atomica.
        IF @cohort_id IS NOT NULL
        BEGIN
            UPDATE cohorts
                SET occupied_slots = occupied_slots + 1
            WHERE id = @cohort_id
              AND active = 1
              AND occupied_slots < max_capacity;

            IF @@ROWCOUNT = 0
                THROW 60010, 'Cupo lleno: la cohorte ya no tiene lugares disponibles.', 1;
        END

        -- 3. Registrar la inscripcion (UX_enrollments_active impide duplicados).
        INSERT INTO enrollments (student_id, course_id, cohort_id, refund_policy_id, amount_paid,
                                 status, settlement_status, progress_percent, enrolled_at)
        VALUES (@student_id, @course_id, @cohort_id, @refund_policy_id, @price,
                'active', 'pending', 0, GETDATE());

        SET @new_enrollment_id = SCOPE_IDENTITY();

        -- 4. Auditoria del cobro en la billetera.
        INSERT INTO wallet_movements (wallet_id, type, concept, amount, enrollment_id, created_at, resulting_balance)
        VALUES (@wallet_id, 'debit', 'enrollment', @price, @new_enrollment_id, GETDATE(), @new_balance);

        INSERT INTO notifications (user_id, type, subject, body)
        VALUES (@student_id, 'enrolled', CONCAT('Inscripcion confirmada: ', @course_title),
                CONCAT('Te inscribiste en "', @course_title, '". Se descontaron Q', @price,
                       ' de tu billetera; saldo actual: Q', @new_balance, '.'));

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        IF ERROR_NUMBER() IN (2601, 2627)
            THROW 60003, 'El estudiante ya tiene una inscripcion activa en este curso.', 1;

        THROW;
    END CATCH
END
