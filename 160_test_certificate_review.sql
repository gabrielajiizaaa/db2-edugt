-- EDUGT — Fase 3
-- Pruebas funcionales: sp_ReviewCertificate, requisito previo con certificado
-- valido y evolucion del progreso en fn_ProgressHistory.
-- Requiere haber ejecutado 140_test_progress.sql (usa sus helpers).

-- Helper: inscribe a un estudiante en un curso nuevo de 3 modulos y lo completa
-- en tiempo implausible (1 min por leccion contra 60 min esperados), de modo
-- que el certificado queda en pending_review. Devuelve la inscripcion y el id
-- del certificado.
CREATE OR ALTER PROCEDURE dbo.test_make_suspicious_certificate
    @title          VARCHAR(200),
    @student_email  VARCHAR(200),
    @student_id     INT OUTPUT,
    @course_id      INT OUTPUT,
    @enrollment_id  INT OUTPUT,
    @certificate_id INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @pct DECIMAL(5,2), @code VARCHAR(30);
    EXEC dbo.test_make_progress_fixture @title, @student_email, 0,
        @student_id OUTPUT, @course_id OUTPUT, @enrollment_id OUTPUT;
    EXEC dbo.test_study_module @enrollment_id, @student_id, 1, 1, @pct OUTPUT, @code OUTPUT;
    EXEC dbo.test_study_module @enrollment_id, @student_id, 2, 1, @pct OUTPUT, @code OUTPUT;
    EXEC dbo.test_study_module @enrollment_id, @student_id, 3, 1, @pct OUTPUT, @code OUTPUT;
    SET @certificate_id = (SELECT id FROM certificates WHERE enrollment_id = @enrollment_id);
END;

CREATE OR ALTER PROCEDURE dbo.test_case_review_validar
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @academic  INT = (SELECT id FROM users WHERE email = 'academic.test@edugt.com');
    DECLARE @academic2 INT = (SELECT id FROM users WHERE email = 'academic2.test@edugt.com');
    DECLARE @s INT, @course INT, @enr INT, @cert INT, @err VARCHAR(2048) = NULL;
    EXEC dbo.test_make_suspicious_certificate 'TEST CertReview Validar', 'certrev1.test@edugt.com',
        @s OUTPUT, @course OUTPUT, @enr OUTPUT, @cert OUTPUT;

    IF EXISTS (SELECT 1 FROM certificates WHERE id = @cert AND status = 'pending_review')
        EXEC dbo.test_pass 'Revision: el certificado sospechoso arranca en pending_review';
    ELSE
        EXEC dbo.test_fail 'Revision: el certificado sospechoso arranca en pending_review';

    BEGIN TRY
        EXEC dbo.sp_ReviewCertificate @academic_id=@academic, @certificate_id=@cert, @decision='valid',
            @comments='Se verifico con el estudiante, ya conocia el tema.';
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH

    IF @err IS NULL AND EXISTS (
        SELECT 1 FROM certificates
        WHERE id = @cert AND status = 'valid'
          AND review_reason LIKE 'Tiempo de estudio implausible%Resuelto como valid%'
    )
        EXEC dbo.test_pass 'Revision: el comite valida y review_reason conserva el motivo y la resolucion';
    ELSE
        EXEC dbo.test_fail 'Revision: el comite valida y review_reason conserva el motivo y la resolucion', @detail=@err;

    IF EXISTS (SELECT 1 FROM notifications WHERE user_id = @s AND type = 'certificate' AND subject LIKE '%fue validado%')
        EXEC dbo.test_pass 'Revision: se notifica al estudiante la validacion';
    ELSE
        EXEC dbo.test_fail 'Revision: se notifica al estudiante la validacion';

    -- Un segundo academico intenta resolver el mismo certificado.
    SET @err = NULL;
    BEGIN TRY
        EXEC dbo.sp_ReviewCertificate @academic_id=@academic2, @certificate_id=@cert, @decision='revoked',
            @comments='Intento tardio';
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Revision: un certificado ya resuelto no se vuelve a resolver', 'no esta pendiente de revision', @err;

    IF EXISTS (SELECT 1 FROM certificates WHERE id = @cert AND status = 'valid')
        EXEC dbo.test_pass 'Revision: la segunda resolucion no altera el estado';
    ELSE
        EXEC dbo.test_fail 'Revision: la segunda resolucion no altera el estado';
END;

CREATE OR ALTER PROCEDURE dbo.test_case_review_revocar
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @academic INT = (SELECT id FROM users WHERE email = 'academic.test@edugt.com');
    DECLARE @s INT, @course INT, @enr INT, @cert INT, @err VARCHAR(2048) = NULL;
    EXEC dbo.test_make_suspicious_certificate 'TEST CertReview Revocar', 'certrev2.test@edugt.com',
        @s OUTPUT, @course OUTPUT, @enr OUTPUT, @cert OUTPUT;

    -- Revocar sin motivo.
    BEGIN TRY
        EXEC dbo.sp_ReviewCertificate @academic_id=@academic, @certificate_id=@cert, @decision='revoked';
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Revision: revocar exige un motivo', 'motivo de la revocacion', @err;

    SET @err = NULL;
    BEGIN TRY
        EXEC dbo.sp_ReviewCertificate @academic_id=@academic, @certificate_id=@cert, @decision='revoked',
            @comments='Completo 60 min de video en 6 min.';
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH

    IF @err IS NULL
       AND EXISTS (SELECT 1 FROM certificates WHERE id = @cert AND status = 'revoked')
       AND EXISTS (SELECT 1 FROM enrollments WHERE id = @enr AND status = 'completed')
       AND EXISTS (SELECT 1 FROM notifications WHERE user_id = @s AND type = 'certificate' AND subject LIKE '%fue revocado%')
        EXEC dbo.test_pass 'Revision: revocado con motivo, la inscripcion sigue completed y se notifica';
    ELSE
        EXEC dbo.test_fail 'Revision: revocado con motivo, la inscripcion sigue completed y se notifica', @detail=@err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_review_validaciones
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @academic INT = (SELECT id FROM users WHERE email = 'academic.test@edugt.com');
    DECLARE @instr    INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DECLARE @s INT, @course INT, @enr INT, @cert INT, @err VARCHAR(2048) = NULL;
    DECLARE @s2 INT, @course2 INT, @enr2 INT, @pct DECIMAL(5,2), @code VARCHAR(30), @cert_valid INT;
    EXEC dbo.test_make_suspicious_certificate 'TEST CertReview Validaciones', 'certrev3.test@edugt.com',
        @s OUTPUT, @course OUTPUT, @enr OUTPUT, @cert OUTPUT;

    BEGIN TRY
        EXEC dbo.sp_ReviewCertificate @academic_id=@instr, @certificate_id=@cert, @decision='valid';
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Revision: solo el comite academico puede resolver', 'comite academico', @err;

    SET @err = NULL;
    BEGIN TRY
        EXEC dbo.sp_ReviewCertificate @academic_id=@academic, @certificate_id=@cert, @decision='approved';
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Revision: rechaza una decision distinta de valid / revoked', 'valid o revoked', @err;

    -- Un certificado emitido como valido no pasa por revision.
    EXEC dbo.test_make_progress_fixture 'TEST CertReview Normal', 'certrev4.test@edugt.com', 0,
        @s2 OUTPUT, @course2 OUTPUT, @enr2 OUTPUT;
    EXEC dbo.test_study_module @enr2, @s2, 1, 20, @pct OUTPUT, @code OUTPUT;
    EXEC dbo.test_study_module @enr2, @s2, 2, 20, @pct OUTPUT, @code OUTPUT;
    EXEC dbo.test_study_module @enr2, @s2, 3, 20, @pct OUTPUT, @code OUTPUT;
    SET @cert_valid = (SELECT id FROM certificates WHERE enrollment_id = @enr2);

    SET @err = NULL;
    BEGIN TRY
        EXEC dbo.sp_ReviewCertificate @academic_id=@academic, @certificate_id=@cert_valid, @decision='revoked',
            @comments='Prueba';
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Revision: un certificado valido no marcado no entra a revision', 'no esta pendiente de revision', @err;
END;

-- Requisito previo: un curso cuyo certificado esta en revision o revocado no
-- cuenta como aprobado hasta que el comite lo valide.
CREATE OR ALTER PROCEDURE dbo.test_case_review_prerequisito
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @academic INT = (SELECT id FROM users WHERE email = 'academic.test@edugt.com');
    DECLARE @s INT, @basico INT, @avanzado INT, @enr INT, @cert INT, @enr_av INT;
    DECLARE @bal DECIMAL(12,2), @err VARCHAR(2048) = NULL;
    DECLARE @s2 INT, @basico2 INT, @avanzado2 INT, @enr2 INT, @cert2 INT;

    -- Caso 1: en revision -> bloqueado; validado -> permitido.
    EXEC dbo.test_make_suspicious_certificate 'TEST CertReview Prereq Basico', 'certrev5.test@edugt.com',
        @s OUTPUT, @basico OUTPUT, @enr OUTPUT, @cert OUTPUT;
    EXEC dbo.test_make_course_full 'TEST CertReview Prereq Avanzado', 100.00, 0, @avanzado OUTPUT;
    INSERT INTO course_prerequisites (course_id, prerequisite_id) VALUES (@avanzado, @basico);
    EXEC dbo.sp_TopUpWallet @s, 100.00, @bal OUTPUT;

    BEGIN TRY
        EXEC dbo.sp_EnrollStudent @student_id=@s, @course_id=@avanzado, @new_enrollment_id=@enr_av OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Prerequisito: con el certificado del requisito en revision no puede inscribirse', 'Requisito previo no aprobado', @err;

    EXEC dbo.sp_ReviewCertificate @academic_id=@academic, @certificate_id=@cert, @decision='valid';

    SET @err = NULL;
    BEGIN TRY
        EXEC dbo.sp_EnrollStudent @student_id=@s, @course_id=@avanzado, @new_enrollment_id=@enr_av OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH

    IF @err IS NULL
        EXEC dbo.test_pass 'Prerequisito: cuando el comite valida el certificado ya puede inscribirse';
    ELSE
        EXEC dbo.test_fail 'Prerequisito: cuando el comite valida el certificado ya puede inscribirse', @detail=@err;

    -- Caso 2: revocado -> bloqueado.
    SET @err = NULL;
    EXEC dbo.test_make_suspicious_certificate 'TEST CertReview Prereq Basico2', 'certrev6.test@edugt.com',
        @s2 OUTPUT, @basico2 OUTPUT, @enr2 OUTPUT, @cert2 OUTPUT;
    EXEC dbo.test_make_course_full 'TEST CertReview Prereq Avanzado2', 100.00, 0, @avanzado2 OUTPUT;
    INSERT INTO course_prerequisites (course_id, prerequisite_id) VALUES (@avanzado2, @basico2);
    EXEC dbo.sp_TopUpWallet @s2, 100.00, @bal OUTPUT;
    EXEC dbo.sp_ReviewCertificate @academic_id=@academic, @certificate_id=@cert2, @decision='revoked',
        @comments='Tiempo implausible confirmado.';

    BEGIN TRY
        EXEC dbo.sp_EnrollStudent @student_id=@s2, @course_id=@avanzado2, @new_enrollment_id=@enr_av OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Prerequisito: con el certificado del requisito revocado no puede inscribirse', 'Requisito previo no aprobado', @err;

    IF (SELECT balance FROM wallets WHERE user_id = @s2) = 100.00
        EXEC dbo.test_pass 'Prerequisito: el rechazo no cobra nada';
    ELSE
        EXEC dbo.test_fail 'Prerequisito: el rechazo no cobra nada';
END;

-- Historial: progress_after_module muestra el avance alcanzado al completar
-- cada modulo (33.33 -> 66.67) y NULL en el modulo pendiente.
CREATE OR ALTER PROCEDURE dbo.test_case_review_historial_evolucion
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s INT, @course INT, @enr INT, @pct DECIMAL(5,2), @code VARCHAR(30);
    EXEC dbo.test_make_progress_fixture 'TEST CertReview Historial', 'certrev7.test@edugt.com', 0,
        @s OUTPUT, @course OUTPUT, @enr OUTPUT;
    EXEC dbo.test_study_module @enr, @s, 1, 20, @pct OUTPUT, @code OUTPUT;
    EXEC dbo.test_study_module @enr, @s, 2, 20, @pct OUTPUT, @code OUTPUT;

    -- Separa los momentos de completado para que la prueba no dependa de la
    -- resolucion de DATETIME (3 ms) entre dos llamadas seguidas.
    UPDATE mp SET completed_at = DATEADD(MINUTE, CASE m.order_index WHEN 1 THEN -10 ELSE -5 END, GETDATE())
    FROM module_progress mp JOIN modules m ON m.id = mp.module_id
    WHERE mp.enrollment_id = @enr;

    IF NOT EXISTS (SELECT 1 FROM dbo.fn_ProgressHistory(@enr) WHERE module_order = 1 AND ISNULL(progress_after_module, -1) <> 33.33)
       AND NOT EXISTS (SELECT 1 FROM dbo.fn_ProgressHistory(@enr) WHERE module_order = 2 AND ISNULL(progress_after_module, -1) <> 66.67)
       AND NOT EXISTS (SELECT 1 FROM dbo.fn_ProgressHistory(@enr) WHERE module_order = 3 AND progress_after_module IS NOT NULL)
       AND (SELECT COUNT(*) FROM dbo.fn_ProgressHistory(@enr)) = 6
        EXEC dbo.test_pass 'Historial: progress_after_module muestra la evolucion 33.33 -> 66.67 y NULL en lo pendiente';
    ELSE
        EXEC dbo.test_fail 'Historial: progress_after_module muestra la evolucion 33.33 -> 66.67 y NULL en lo pendiente';
END;

-- EJECUTAR TODOS
PRINT 'PRUEBAS FUNCIONALES: REVISION DE CERTIFICADOS Y REQUISITO CON CERTIFICADO VALIDO';

EXEC dbo.test_ensure_refund_policy;
EXEC dbo.test_cleanup_courses 'TEST CertReview%';
EXEC dbo.test_cleanup_test_wallets;
EXEC dbo.test_case_review_validar;
EXEC dbo.test_case_review_revocar;
EXEC dbo.test_case_review_validaciones;
EXEC dbo.test_case_review_prerequisito;
EXEC dbo.test_case_review_historial_evolucion;
EXEC dbo.test_cleanup_courses 'TEST CertReview%';
EXEC dbo.test_cleanup_test_wallets;

PRINT '';
