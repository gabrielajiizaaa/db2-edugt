-- EDUGT — Fase 3
-- Pruebas funcionales: sp_StartLesson, sp_CompleteLesson, sp_CompleteModule,
-- emision automatica de certificados y fn_ProgressHistory

-- Helper: inscribe a un estudiante (via sp_EnrollStudent) en un curso nuevo.
CREATE OR ALTER PROCEDURE dbo.test_make_progress_fixture
    @title         VARCHAR(200),
    @student_email VARCHAR(200),
    @with_exam     BIT,
    @student_id    INT OUTPUT,
    @course_id     INT OUTPUT,
    @enrollment_id INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @bal DECIMAL(12,2);
    EXEC dbo.test_ensure_student @student_email, @student_id OUTPUT;
    EXEC dbo.test_make_course_full @title, 100.00, @with_exam, @course_id OUTPUT;
    EXEC dbo.sp_TopUpWallet @student_id, 100.00, @bal OUTPUT;
    EXEC dbo.sp_EnrollStudent @student_id=@student_id, @course_id=@course_id, @new_enrollment_id=@enrollment_id OUTPUT;
END;

-- Helper: estudia una leccion (inicio y fin) simulando @minutes de estudio.
-- started_at se retrasa @minutes para no esperar en tiempo real.
CREATE OR ALTER PROCEDURE dbo.test_study_lesson
    @enrollment_id INT,
    @student_id    INT,
    @lesson_id     INT,
    @minutes       INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @already BIT;
    EXEC dbo.sp_StartLesson @enrollment_id, @student_id, @lesson_id;
    UPDATE lesson_progress
        SET started_at = DATEADD(MINUTE, -@minutes, GETDATE())
    WHERE enrollment_id = @enrollment_id AND lesson_id = @lesson_id AND completed_at IS NULL;
    EXEC dbo.sp_CompleteLesson @enrollment_id, @student_id, @lesson_id, @already OUTPUT;
END;

-- Helper: estudia todas las lecciones de un modulo y lo marca completado.
CREATE OR ALTER PROCEDURE dbo.test_study_module
    @enrollment_id    INT,
    @student_id       INT,
    @module_order     INT,
    @minutes          INT,
    @progress_percent DECIMAL(5,2) OUTPUT,
    @certificate_code VARCHAR(30) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @module INT, @lesson INT, @already BIT;
    SELECT @module = m.id
    FROM modules m JOIN enrollments e ON e.course_id = m.course_id
    WHERE e.id = @enrollment_id AND m.order_index = @module_order;

    DECLARE lessons_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT id FROM lessons WHERE module_id = @module ORDER BY order_index;
    OPEN lessons_cur;
    FETCH NEXT FROM lessons_cur INTO @lesson;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.test_study_lesson @enrollment_id, @student_id, @lesson, @minutes;
        FETCH NEXT FROM lessons_cur INTO @lesson;
    END
    CLOSE lessons_cur;
    DEALLOCATE lessons_cur;

    EXEC dbo.sp_CompleteModule @enrollment_id, @student_id, @module,
        @progress_percent OUTPUT, @already OUTPUT, @certificate_code OUTPUT;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_progress_lecciones
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s INT, @course INT, @enr INT, @lesson INT, @already BIT, @first DATETIME, @err VARCHAR(2048) = NULL;
    EXEC dbo.test_make_progress_fixture 'TEST Progress Lecciones', 'progress1.test@edugt.com', 0, @s OUTPUT, @course OUTPUT, @enr OUTPUT;
    SELECT TOP 1 @lesson = l.id FROM lessons l JOIN modules m ON m.id = l.module_id WHERE m.course_id = @course ORDER BY m.order_index, l.order_index;

    -- Completar sin iniciar.
    BEGIN TRY EXEC dbo.sp_CompleteLesson @enr, @s, @lesson, @already OUTPUT; END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Leccion: no se puede completar sin haberla iniciado', 'Debe iniciar la leccion', @err;

    -- Iniciar dos veces conserva el inicio original y una sola fila.
    EXEC dbo.sp_StartLesson @enr, @s, @lesson;
    SET @first = (SELECT started_at FROM lesson_progress WHERE enrollment_id = @enr AND lesson_id = @lesson);
    EXEC dbo.sp_StartLesson @enr, @s, @lesson;

    IF (SELECT COUNT(*) FROM lesson_progress WHERE enrollment_id = @enr AND lesson_id = @lesson) = 1
       AND (SELECT started_at FROM lesson_progress WHERE enrollment_id = @enr AND lesson_id = @lesson) = @first
        EXEC dbo.test_pass 'Leccion: iniciarla dos veces conserva el inicio original (idempotente)';
    ELSE
        EXEC dbo.test_fail 'Leccion: iniciarla dos veces conserva el inicio original (idempotente)';

    -- Completar dos veces: la segunda informa ya completada y no cambia el momento.
    EXEC dbo.sp_CompleteLesson @enr, @s, @lesson, @already OUTPUT;
    SET @first = (SELECT completed_at FROM lesson_progress WHERE enrollment_id = @enr AND lesson_id = @lesson);
    EXEC dbo.sp_CompleteLesson @enr, @s, @lesson, @already OUTPUT;

    IF @already = 1 AND (SELECT completed_at FROM lesson_progress WHERE enrollment_id = @enr AND lesson_id = @lesson) = @first
        EXEC dbo.test_pass 'Leccion: completarla dos veces no sobrescribe el momento del avance';
    ELSE
        EXEC dbo.test_fail 'Leccion: completarla dos veces no sobrescribe el momento del avance';
END;

CREATE OR ALTER PROCEDURE dbo.test_case_progress_modulo
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s INT, @course INT, @enr INT, @module INT, @pct DECIMAL(5,2), @already BIT, @code VARCHAR(30);
    DECLARE @err VARCHAR(2048) = NULL;
    EXEC dbo.test_make_progress_fixture 'TEST Progress Modulo', 'progress2.test@edugt.com', 0, @s OUTPUT, @course OUTPUT, @enr OUTPUT;
    SELECT @module = id FROM modules WHERE course_id = @course AND order_index = 1;

    -- Modulo con lecciones pendientes.
    BEGIN TRY EXEC dbo.sp_CompleteModule @enr, @s, @module, @pct OUTPUT, @already OUTPUT; END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Modulo: no se completa si faltan lecciones', 'completar todas las lecciones', @err;

    EXEC dbo.test_study_module @enr, @s, 1, 20, @pct OUTPUT, @code OUTPUT;

    IF @pct = 33.33 AND (SELECT progress_percent FROM enrollments WHERE id = @enr) = 33.33
       AND EXISTS (SELECT 1 FROM module_progress WHERE enrollment_id = @enr AND module_id = @module
                   AND completed = 1 AND completed_at IS NOT NULL)
        EXEC dbo.test_pass 'Modulo: 1 de 3 completado deja el progreso en 33.33% con el momento registrado';
    ELSE
        EXEC dbo.test_fail 'Modulo: 1 de 3 completado deja el progreso en 33.33% con el momento registrado';

    -- Segundo dispositivo reporta el mismo modulo.
    EXEC dbo.sp_CompleteModule @enr, @s, @module, @pct OUTPUT, @already OUTPUT;

    IF @already = 1 AND @pct = 33.33
       AND (SELECT COUNT(*) FROM module_progress WHERE enrollment_id = @enr AND module_id = @module) = 1
        EXEC dbo.test_pass 'Modulo: reportarlo otra vez no lo duplica ni altera el progreso';
    ELSE
        EXEC dbo.test_fail 'Modulo: reportarlo otra vez no lo duplica ni altera el progreso';
END;

CREATE OR ALTER PROCEDURE dbo.test_case_progress_certificado_sin_examen
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s INT, @course INT, @enr INT, @pct DECIMAL(5,2), @code VARCHAR(30);
    EXEC dbo.test_make_progress_fixture 'TEST Progress SinExamen', 'progress3.test@edugt.com', 0, @s OUTPUT, @course OUTPUT, @enr OUTPUT;

    -- 20 min por leccion de video: tiempo real = esperado.
    EXEC dbo.test_study_module @enr, @s, 1, 20, @pct OUTPUT, @code OUTPUT;
    EXEC dbo.test_study_module @enr, @s, 2, 20, @pct OUTPUT, @code OUTPUT;

    IF @code IS NULL AND @pct = 66.67
        EXEC dbo.test_pass 'Certificado auto: no se emite antes del 100%';
    ELSE
        EXEC dbo.test_fail 'Certificado auto: no se emite antes del 100%';

    EXEC dbo.test_study_module @enr, @s, 3, 20, @pct OUTPUT, @code OUTPUT;

    IF @pct = 100 AND @code IS NOT NULL
       AND EXISTS (SELECT 1 FROM certificates WHERE code = @code AND enrollment_id = @enr AND status = 'valid')
       AND EXISTS (SELECT 1 FROM enrollments WHERE id = @enr AND status = 'completed')
        EXEC dbo.test_pass 'Certificado auto: al completar el ultimo modulo se emite valido y la inscripcion queda completed';
    ELSE
        EXEC dbo.test_fail 'Certificado auto: al completar el ultimo modulo se emite valido y la inscripcion queda completed';
END;

CREATE OR ALTER PROCEDURE dbo.test_case_progress_certificado_con_examen
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s INT, @course INT, @enr INT, @pct DECIMAL(5,2), @code VARCHAR(30);
    DECLARE @att_id INT, @att_num INT, @passed BIT;
    EXEC dbo.test_make_progress_fixture 'TEST Progress ConExamen', 'progress4.test@edugt.com', 1, @s OUTPUT, @course OUTPUT, @enr OUTPUT;

    EXEC dbo.test_study_module @enr, @s, 1, 20, @pct OUTPUT, @code OUTPUT;
    EXEC dbo.test_study_module @enr, @s, 2, 20, @pct OUTPUT, @code OUTPUT;
    EXEC dbo.test_study_module @enr, @s, 3, 20, @pct OUTPUT, @code OUTPUT;

    IF @pct = 100 AND @code IS NULL AND EXISTS (SELECT 1 FROM enrollments WHERE id = @enr AND status = 'active')
        EXEC dbo.test_pass 'Certificado auto: con examen pendiente, el 100% de modulos no basta';
    ELSE
        EXEC dbo.test_fail 'Certificado auto: con examen pendiente, el 100% de modulos no basta';

    EXEC dbo.sp_RegisterExamAttempt @enr, @s, 60.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT, @code OUTPUT;
    EXEC dbo.sp_RegisterExamAttempt @enr, @s, 85.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT, @code OUTPUT;

    IF @att_num = 2 AND @passed = 1 AND @code IS NOT NULL
       AND EXISTS (SELECT 1 FROM certificates WHERE code = @code AND status = 'valid')
        EXEC dbo.test_pass 'Certificado auto: se emite al aprobar el examen en el segundo intento';
    ELSE
        EXEC dbo.test_fail 'Certificado auto: se emite al aprobar el examen en el segundo intento';
END;

CREATE OR ALTER PROCEDURE dbo.test_case_progress_fraude
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s INT, @course INT, @enr INT, @pct DECIMAL(5,2), @code VARCHAR(30);
    EXEC dbo.test_make_progress_fixture 'TEST Progress Fraude', 'progress5.test@edugt.com', 0, @s OUTPUT, @course OUTPUT, @enr OUTPUT;

    -- Caso Kevin: un curso de 60 min completado en ~6 min (1 min por leccion).
    EXEC dbo.test_study_module @enr, @s, 1, 1, @pct OUTPUT, @code OUTPUT;
    EXEC dbo.test_study_module @enr, @s, 2, 1, @pct OUTPUT, @code OUTPUT;
    EXEC dbo.test_study_module @enr, @s, 3, 1, @pct OUTPUT, @code OUTPUT;

    IF EXISTS (SELECT 1 FROM certificates WHERE code = @code AND status = 'pending_review')
        EXEC dbo.test_pass 'Certificado auto: curso completado en tiempo implausible queda pending_review';
    ELSE
        EXEC dbo.test_fail 'Certificado auto: curso completado en tiempo implausible queda pending_review';
END;

CREATE OR ALTER PROCEDURE dbo.test_case_progress_historial
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s INT, @course INT, @enr INT, @pct DECIMAL(5,2), @code VARCHAR(30);
    EXEC dbo.test_make_progress_fixture 'TEST Progress Historial', 'progress6.test@edugt.com', 0, @s OUTPUT, @course OUTPUT, @enr OUTPUT;
    EXEC dbo.test_study_module @enr, @s, 1, 20, @pct OUTPUT, @code OUTPUT;

    -- 3 modulos x 2 lecciones = 6 filas; las 2 del modulo 1 con tiempos.
    IF (SELECT COUNT(*) FROM dbo.fn_ProgressHistory(@enr)) = 6
       AND (SELECT COUNT(*) FROM dbo.fn_ProgressHistory(@enr)
            WHERE module_order = 1 AND module_completed = 1 AND lesson_completed_at IS NOT NULL) = 2
       AND (SELECT COUNT(*) FROM dbo.fn_ProgressHistory(@enr) WHERE lesson_started_at IS NULL) = 4
        EXEC dbo.test_pass 'Historial: fn_ProgressHistory muestra cada leccion con su momento de avance';
    ELSE
        EXEC dbo.test_fail 'Historial: fn_ProgressHistory muestra cada leccion con su momento de avance';
END;

-- EJECUTAR TODOS
PRINT 'PRUEBAS FUNCIONALES: PROGRESO Y CERTIFICADO AUTOMATICO';

EXEC dbo.test_ensure_refund_policy;
EXEC dbo.test_cleanup_courses 'TEST Progress%';
EXEC dbo.test_cleanup_test_wallets;
EXEC dbo.test_case_progress_lecciones;
EXEC dbo.test_case_progress_modulo;
EXEC dbo.test_case_progress_certificado_sin_examen;
EXEC dbo.test_case_progress_certificado_con_examen;
EXEC dbo.test_case_progress_fraude;
EXEC dbo.test_case_progress_historial;
EXEC dbo.test_cleanup_courses 'TEST Progress%';
EXEC dbo.test_cleanup_test_wallets;

PRINT '';
