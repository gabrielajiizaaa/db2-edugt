-- EDUGT — Fase 3
-- Pruebas funcionales: sp_TopUpWallet y sp_EnrollStudent

CREATE OR ALTER PROCEDURE dbo.test_case_wallet_recarga
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s INT, @bal DECIMAL(12,2), @err VARCHAR(2048) = NULL;
    EXEC dbo.test_ensure_student 'enroll1.test@edugt.com', @s OUTPUT;

    EXEC dbo.sp_TopUpWallet @s, 150.00, @bal OUTPUT;
    EXEC dbo.sp_TopUpWallet @s, 50.00, @bal OUTPUT;

    IF @bal = 200.00 AND (SELECT balance FROM wallets WHERE user_id = @s) = 200.00
        EXEC dbo.test_pass 'Billetera: la primera recarga crea la billetera y las recargas se acumulan';
    ELSE
        EXEC dbo.test_fail 'Billetera: la primera recarga crea la billetera y las recargas se acumulan';

    IF (SELECT COUNT(*) FROM wallet_movements wm JOIN wallets w ON w.id = wm.wallet_id
        WHERE w.user_id = @s AND wm.type = 'credit' AND wm.concept = 'adjustment') = 2
        EXEC dbo.test_pass 'Billetera: cada recarga queda en wallet_movements como credit';
    ELSE
        EXEC dbo.test_fail 'Billetera: cada recarga queda en wallet_movements como credit';

    BEGIN TRY EXEC dbo.sp_TopUpWallet @s, -10.00, @bal OUTPUT; END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Billetera: rechaza recarga con monto no positivo', 'mayor a cero', @err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_enroll_ok
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s INT, @course INT, @enr INT, @bal DECIMAL(12,2), @err VARCHAR(2048) = NULL;
    EXEC dbo.test_ensure_student 'enroll2.test@edugt.com', @s OUTPUT;
    EXEC dbo.test_make_course_full 'TEST Enroll Ok', 250.00, 0, @course OUTPUT;
    EXEC dbo.sp_TopUpWallet @s, 300.00, @bal OUTPUT;

    BEGIN TRY
        EXEC dbo.sp_EnrollStudent @student_id=@s, @course_id=@course, @new_enrollment_id=@enr OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH

    IF @err IS NULL AND EXISTS (
        SELECT 1 FROM enrollments
        WHERE id = @enr AND status = 'active' AND settlement_status = 'pending'
          AND amount_paid = 250.00 AND progress_percent = 0
          AND refund_policy_id = (SELECT id FROM refund_policies WHERE active = 1)
    )
        EXEC dbo.test_pass 'Inscripcion: queda activa, pendiente de liquidacion y con snapshot de la politica vigente';
    ELSE
        EXEC dbo.test_fail 'Inscripcion: queda activa, pendiente de liquidacion y con snapshot de la politica vigente', @detail=@err;

    IF (SELECT balance FROM wallets WHERE user_id = @s) = 50.00
       AND EXISTS (SELECT 1 FROM wallet_movements WHERE enrollment_id = @enr AND type = 'debit'
                   AND concept = 'enrollment' AND amount = 250.00 AND resulting_balance = 50.00)
        EXEC dbo.test_pass 'Inscripcion: descuenta el precio y registra el debito con el saldo resultante';
    ELSE
        EXEC dbo.test_fail 'Inscripcion: descuenta el precio y registra el debito con el saldo resultante';

    IF EXISTS (SELECT 1 FROM notifications WHERE user_id = @s AND type = 'enrolled')
        EXEC dbo.test_pass 'Inscripcion: se notifica al estudiante';
    ELSE
        EXEC dbo.test_fail 'Inscripcion: se notifica al estudiante';

    SET @err = NULL;
    EXEC dbo.sp_TopUpWallet @s, 500.00, @bal OUTPUT;
    BEGIN TRY
        EXEC dbo.sp_EnrollStudent @student_id=@s, @course_id=@course, @new_enrollment_id=@enr OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Inscripcion: rechaza una segunda inscripcion activa en el mismo curso', 'ya tiene una inscripcion activa', @err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_enroll_saldo
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s INT, @course INT, @enr INT, @bal DECIMAL(12,2), @err VARCHAR(2048) = NULL;
    EXEC dbo.test_ensure_student 'enroll3.test@edugt.com', @s OUTPUT;
    EXEC dbo.test_make_course_full 'TEST Enroll Saldo', 250.00, 0, @course OUTPUT;
    EXEC dbo.sp_TopUpWallet @s, 100.00, @bal OUTPUT;

    BEGIN TRY
        EXEC dbo.sp_EnrollStudent @student_id=@s, @course_id=@course, @new_enrollment_id=@enr OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Inscripcion: rechaza con saldo insuficiente', 'Saldo insuficiente', @err;

    IF (SELECT balance FROM wallets WHERE user_id = @s) = 100.00
       AND NOT EXISTS (SELECT 1 FROM enrollments WHERE student_id = @s AND course_id = @course)
       AND NOT EXISTS (SELECT 1 FROM wallet_movements wm JOIN wallets w ON w.id = wm.wallet_id
                       WHERE w.user_id = @s AND wm.type = 'debit')
        EXEC dbo.test_pass 'Inscripcion: el fallo no deja rastro parcial (saldo, inscripcion ni movimiento)';
    ELSE
        EXEC dbo.test_fail 'Inscripcion: el fallo no deja rastro parcial (saldo, inscripcion ni movimiento)';
END;

CREATE OR ALTER PROCEDURE dbo.test_case_enroll_no_disponible
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s INT, @course INT, @enr INT, @bal DECIMAL(12,2), @err VARCHAR(2048) = NULL;
    EXEC dbo.test_ensure_student 'enroll1.test@edugt.com', @s OUTPUT;
    EXEC dbo.test_make_course_full 'TEST Enroll Pendiente', 100.00, 0, @course OUTPUT;
    UPDATE courses SET status = 'pending', published_at = NULL WHERE id = @course;

    BEGIN TRY
        EXEC dbo.sp_EnrollStudent @student_id=@s, @course_id=@course, @new_enrollment_id=@enr OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Inscripcion: rechaza curso que no esta disponible', 'no esta disponible', @err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_enroll_sin_billetera
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s INT, @course INT, @enr INT, @err VARCHAR(2048) = NULL;
    EXEC dbo.test_ensure_student 'enroll4.test@edugt.com', @s OUTPUT;
    EXEC dbo.test_make_course_full 'TEST Enroll SinBilletera', 100.00, 0, @course OUTPUT;

    BEGIN TRY
        EXEC dbo.sp_EnrollStudent @student_id=@s, @course_id=@course, @new_enrollment_id=@enr OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Inscripcion: rechaza estudiante sin billetera', 'no tiene billetera', @err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_enroll_prerequisito
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s INT, @basico INT, @avanzado INT, @enr_basico INT, @enr INT;
    DECLARE @bal DECIMAL(12,2), @err VARCHAR(2048) = NULL;
    EXEC dbo.test_ensure_student 'enroll5.test@edugt.com', @s OUTPUT;
    EXEC dbo.test_make_course_full 'TEST Enroll Excel Basico', 100.00, 0, @basico OUTPUT;
    EXEC dbo.test_make_course_full 'TEST Enroll Excel Avanzado', 100.00, 0, @avanzado OUTPUT;
    INSERT INTO course_prerequisites (course_id, prerequisite_id) VALUES (@avanzado, @basico);
    EXEC dbo.sp_TopUpWallet @s, 500.00, @bal OUTPUT;

    -- Sin haber cursado el basico.
    BEGIN TRY
        EXEC dbo.sp_EnrollStudent @student_id=@s, @course_id=@avanzado, @new_enrollment_id=@enr OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Inscripcion: rechaza si no tiene inscripcion en el requisito previo', 'Requisito previo no aprobado', @err;

    -- Inscrito en el basico pero sin completarlo.
    SET @err = NULL;
    EXEC dbo.sp_EnrollStudent @student_id=@s, @course_id=@basico, @new_enrollment_id=@enr_basico OUTPUT;
    BEGIN TRY
        EXEC dbo.sp_EnrollStudent @student_id=@s, @course_id=@avanzado, @new_enrollment_id=@enr OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Inscripcion: rechaza si el requisito previo no esta completado', 'Requisito previo no aprobado', @err;

    -- Completa el basico: ahora si puede inscribirse.
    SET @err = NULL;
    UPDATE enrollments SET status = 'completed', completed_at = GETDATE(), progress_percent = 100 WHERE id = @enr_basico;
    BEGIN TRY
        EXEC dbo.sp_EnrollStudent @student_id=@s, @course_id=@avanzado, @new_enrollment_id=@enr OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH

    IF @err IS NULL
        EXEC dbo.test_pass 'Inscripcion: con el requisito previo aprobado se permite la inscripcion';
    ELSE
        EXEC dbo.test_fail 'Inscripcion: con el requisito previo aprobado se permite la inscripcion', @detail=@err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_enroll_cohorte
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @admin INT = (SELECT id FROM users WHERE email = 'admin.test@edugt.com');
    DECLARE @s1 INT, @s2 INT, @course INT, @cohort INT, @enr INT;
    DECLARE @bal DECIMAL(12,2), @err VARCHAR(2048) = NULL, @start DATETIME = DATEADD(DAY, 7, GETDATE());
    EXEC dbo.test_ensure_student 'enroll6.test@edugt.com', @s1 OUTPUT;
    EXEC dbo.test_ensure_student 'enroll7.test@edugt.com', @s2 OUTPUT;
    EXEC dbo.test_make_course_full 'TEST Enroll EnVivo', 100.00, 0, @course OUTPUT;
    EXEC dbo.sp_CreateCohort @admin_id=@admin, @course_id=@course, @name='Cohorte unica',
        @starts_at=@start, @max_capacity=1, @new_cohort_id=@cohort OUTPUT;
    EXEC dbo.sp_TopUpWallet @s1, 200.00, @bal OUTPUT;
    EXEC dbo.sp_TopUpWallet @s2, 200.00, @bal OUTPUT;

    -- Curso en vivo sin elegir cohorte.
    BEGIN TRY
        EXEC dbo.sp_EnrollStudent @student_id=@s1, @course_id=@course, @new_enrollment_id=@enr OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Cohorte: curso en vivo exige elegir una cohorte', 'debe elegir una cohorte', @err;

    -- Toma el unico lugar.
    SET @err = NULL;
    BEGIN TRY
        EXEC dbo.sp_EnrollStudent @student_id=@s1, @course_id=@course, @cohort_id=@cohort, @new_enrollment_id=@enr OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH

    IF @err IS NULL AND (SELECT occupied_slots FROM cohorts WHERE id = @cohort) = 1
        EXEC dbo.test_pass 'Cohorte: la inscripcion ocupa un lugar';
    ELSE
        EXEC dbo.test_fail 'Cohorte: la inscripcion ocupa un lugar', @detail=@err;

    -- Segundo estudiante: cupo lleno, sin cobro.
    SET @err = NULL;
    BEGIN TRY
        EXEC dbo.sp_EnrollStudent @student_id=@s2, @course_id=@course, @cohort_id=@cohort, @new_enrollment_id=@enr OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Cohorte: rechaza con cupo lleno', 'Cupo lleno', @err;

    IF (SELECT balance FROM wallets WHERE user_id = @s2) = 200.00
       AND (SELECT occupied_slots FROM cohorts WHERE id = @cohort)
           = (SELECT COUNT(*) FROM enrollments WHERE cohort_id = @cohort AND status = 'active')
        EXEC dbo.test_pass 'Cohorte: el rechazo revierte el cobro y occupied_slots = inscripciones activas';
    ELSE
        EXEC dbo.test_fail 'Cohorte: el rechazo revierte el cobro y occupied_slots = inscripciones activas';
END;

-- EJECUTAR TODOS
PRINT 'PRUEBAS FUNCIONALES: BILLETERA E INSCRIPCION';

EXEC dbo.test_ensure_refund_policy;
EXEC dbo.test_cleanup_courses 'TEST Enroll%';
EXEC dbo.test_cleanup_test_wallets;
EXEC dbo.test_case_wallet_recarga;
EXEC dbo.test_case_enroll_ok;
EXEC dbo.test_case_enroll_saldo;
EXEC dbo.test_case_enroll_no_disponible;
EXEC dbo.test_case_enroll_sin_billetera;
EXEC dbo.test_case_enroll_prerequisito;
EXEC dbo.test_case_enroll_cohorte;
EXEC dbo.test_cleanup_courses 'TEST Enroll%';
EXEC dbo.test_cleanup_test_wallets;

PRINT '';
