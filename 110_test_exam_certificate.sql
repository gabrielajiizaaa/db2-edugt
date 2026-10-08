-- EDUGT — Fase 3
-- Pruebas funcionales: sp_CreateExam, sp_RegisterExamAttempt y sp_IssueCertificate

-- Datos base: dos estudiantes de prueba y una politica de reembolso inactiva
-- (marcada con deadline_days = 9999) para satisfacer FK_enr_policy sin
-- interferir con la politica vigente que maneja sp_SetRefundPolicy.
IF NOT EXISTS (SELECT 1 FROM users WHERE email = 'student.test@edugt.com')
    INSERT INTO users (first_name, last_name, email, password_hash, role)
    VALUES ('Student', 'One', 'student.test@edugt.com', 'hash', 'student');

IF NOT EXISTS (SELECT 1 FROM users WHERE email = 'student2.test@edugt.com')
    INSERT INTO users (first_name, last_name, email, password_hash, role)
    VALUES ('Student', 'Two', 'student2.test@edugt.com', 'hash', 'student');

IF NOT EXISTS (SELECT 1 FROM refund_policies WHERE deadline_days = 9999 AND active = 0)
    INSERT INTO refund_policies (deadline_days, max_progress_percent, valid_from, valid_until, active)
    VALUES (9999, 50.00, '2000-01-01', '2000-01-02', 0);

-- Helper: crea un curso disponible con 1 modulo, 3 lecciones (2 videos de 30 min
-- y 1 documento sin duracion), examen final (aprobacion 70, max 3 intentos) y
-- una inscripcion activa del estudiante indicado.
-- Duracion esperada del curso para deteccion de fraude: 60 min.
CREATE OR ALTER PROCEDURE dbo.test_make_exam_fixture
    @title         VARCHAR(200),
    @student_email VARCHAR(200),
    @course_id     INT OUTPUT,
    @enrollment_id INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @category INT = (SELECT id FROM categories WHERE name = 'Categoria Test');
    DECLARE @student  INT = (SELECT id FROM users WHERE email = @student_email);
    DECLARE @policy   INT = (SELECT TOP 1 id FROM refund_policies WHERE deadline_days = 9999 AND active = 0);
    DECLARE @module   INT;

    INSERT INTO courses (code, title, description, category_id, price, status, published_at)
    VALUES (CONCAT('EDU-EC-', RIGHT(CONVERT(VARCHAR(36), NEWID()), 8)),
            @title, 'Curso de prueba de examen y certificado', @category, 100.00, 'available', GETDATE());
    SET @course_id = SCOPE_IDENTITY();

    INSERT INTO modules (course_id, title, description, order_index)
    VALUES (@course_id, 'Modulo 1', 'Unico modulo', 1);
    SET @module = SCOPE_IDENTITY();

    INSERT INTO lessons (module_id, title, type, content_url, duration_min, order_index) VALUES
        (@module, 'Leccion 1', 'video',    'http://c/1', 30,   1),
        (@module, 'Leccion 2', 'video',    'http://c/2', 30,   2),
        (@module, 'Leccion 3', 'document', 'http://c/3', NULL, 3);

    INSERT INTO exams (course_id, title, passing_score, max_attempts)
    VALUES (@course_id, 'Examen final', 70.00, 3);

    INSERT INTO enrollments (student_id, course_id, refund_policy_id, amount_paid, status)
    VALUES (@student, @course_id, @policy, 100.00, 'active');
    SET @enrollment_id = SCOPE_IDENTITY();
END;

-- Helper: deja el curso completado al 100% sin pasar por los SPs de avance
-- (para aislar estas pruebas de sp_CompleteModule): cada leccion con
-- @minutes_per_lesson minutos de estudio y todos los modulos completados.
CREATE OR ALTER PROCEDURE dbo.test_complete_course
    @enrollment_id      INT,
    @minutes_per_lesson INT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO lesson_progress (enrollment_id, lesson_id, started_at, completed_at)
    SELECT @enrollment_id, l.id, DATEADD(MINUTE, -@minutes_per_lesson, GETDATE()), GETDATE()
    FROM enrollments e
    JOIN modules m ON m.course_id = e.course_id
    JOIN lessons l ON l.module_id = m.id
    WHERE e.id = @enrollment_id;

    INSERT INTO module_progress (enrollment_id, module_id, completed, completed_at, version)
    SELECT @enrollment_id, m.id, 1, GETDATE(), 1
    FROM enrollments e
    JOIN modules m ON m.course_id = e.course_id
    WHERE e.id = @enrollment_id;

    UPDATE enrollments SET progress_percent = 100 WHERE id = @enrollment_id;
END;

-- sp_CreateExam

CREATE OR ALTER PROCEDURE dbo.test_case_exam_crear
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @instr   INT = (SELECT id FROM users WHERE email = 'instructor.test@edugt.com');
    DECLARE @coinstr INT = (SELECT id FROM users WHERE email = 'coinstructor.test@edugt.com');
    DECLARE @category INT = (SELECT id FROM categories WHERE name = 'Categoria Test');
    DECLARE @course INT, @exam INT, @err VARCHAR(2048) = NULL;

    INSERT INTO courses (code, title, description, category_id, price, status)
    VALUES (CONCAT('EDU-EC-', RIGHT(CONVERT(VARCHAR(36), NEWID()), 8)),
            'TEST ExamCert CrearExamen', 'Curso para sp_CreateExam', @category, 100.00, 'pending');
    SET @course = SCOPE_IDENTITY();
    INSERT INTO course_instructors (course_id, instructor_id, is_main, share_percent) VALUES
        (@course, @instr, 1, 70.00), (@course, @coinstr, 0, 30.00);

    BEGIN TRY
        EXEC dbo.sp_CreateExam @instructor_id=@instr, @course_id=@course, @title='Final', @new_exam_id=@exam OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH

    IF @err IS NULL AND EXISTS (SELECT 1 FROM exams WHERE id = @exam AND passing_score = 70 AND max_attempts = 3)
        EXEC dbo.test_pass 'CreateExam: instructor principal crea examen con defaults 70 / 3';
    ELSE
        EXEC dbo.test_fail 'CreateExam: instructor principal crea examen con defaults 70 / 3', @detail=@err;

    SET @err = NULL;
    BEGIN TRY
        EXEC dbo.sp_CreateExam @instructor_id=@instr, @course_id=@course, @title='Otro', @new_exam_id=@exam OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'CreateExam: rechaza un segundo examen para el mismo curso', 'ya tiene un examen', @err;

    DELETE FROM exams WHERE course_id = @course;
    SET @err = NULL;
    BEGIN TRY
        EXEC dbo.sp_CreateExam @instructor_id=@coinstr, @course_id=@course, @title='Final', @new_exam_id=@exam OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'CreateExam: rechaza a un co-instructor', 'instructor principal', @err;

    SET @err = NULL;
    BEGIN TRY
        EXEC dbo.sp_CreateExam @instructor_id=@instr, @course_id=@course, @title='Final',
            @passing_score=150, @new_exam_id=@exam OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'CreateExam: rechaza nota minima fuera de 0-100', 'entre 0 y 100', @err;
END;

-- sp_RegisterExamAttempt

CREATE OR ALTER PROCEDURE dbo.test_case_exam_primer_intento
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @student INT = (SELECT id FROM users WHERE email = 'student.test@edugt.com');
    DECLARE @course INT, @enr INT, @att_id INT, @att_num INT, @passed BIT, @err VARCHAR(2048) = NULL;

    EXEC dbo.test_make_exam_fixture 'TEST ExamCert PrimerIntento', 'student.test@edugt.com', @course OUTPUT, @enr OUTPUT;

    BEGIN TRY
        EXEC dbo.sp_RegisterExamAttempt @enrollment_id=@enr, @student_id=@student, @score=50.00,
            @attempt_id=@att_id OUTPUT, @attempt_number=@att_num OUTPUT, @passed=@passed OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH

    IF @err IS NULL AND @att_num = 1 AND @passed = 0
        EXEC dbo.test_pass 'Examen: primer intento reprobado queda como intento 1, passed = 0';
    ELSE
        EXEC dbo.test_fail 'Examen: primer intento reprobado queda como intento 1, passed = 0', @detail=@err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_exam_max_intentos
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @student INT = (SELECT id FROM users WHERE email = 'student.test@edugt.com');
    DECLARE @course INT, @enr INT, @att_id INT, @att_num INT, @passed BIT, @err VARCHAR(2048) = NULL;

    EXEC dbo.test_make_exam_fixture 'TEST ExamCert MaxIntentos', 'student.test@edugt.com', @course OUTPUT, @enr OUTPUT;

    EXEC dbo.sp_RegisterExamAttempt @enr, @student, 40.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT;
    EXEC dbo.sp_RegisterExamAttempt @enr, @student, 50.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT;
    EXEC dbo.sp_RegisterExamAttempt @enr, @student, 60.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT;

    BEGIN TRY
        EXEC dbo.sp_RegisterExamAttempt @enr, @student, 90.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Examen: rechaza un cuarto intento (max_attempts = 3)', 'maximo de intentos', @err;

    IF (SELECT COUNT(*) FROM exam_attempts WHERE enrollment_id = @enr) = 3
        EXEC dbo.test_pass 'Examen: solo quedan registrados 3 intentos';
    ELSE
        EXEC dbo.test_fail 'Examen: solo quedan registrados 3 intentos';
END;

CREATE OR ALTER PROCEDURE dbo.test_case_exam_ya_aprobado
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @student INT = (SELECT id FROM users WHERE email = 'student.test@edugt.com');
    DECLARE @course INT, @enr INT, @att_id INT, @att_num INT, @passed BIT, @err VARCHAR(2048) = NULL;

    -- Curso sin completar: aprueba el examen pero aun no recibe certificado.
    EXEC dbo.test_make_exam_fixture 'TEST ExamCert YaAprobado', 'student.test@edugt.com', @course OUTPUT, @enr OUTPUT;
    EXEC dbo.sp_RegisterExamAttempt @enr, @student, 85.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT;

    IF @passed = 1
        EXEC dbo.test_pass 'Examen: nota >= passing_score queda como aprobado';
    ELSE
        EXEC dbo.test_fail 'Examen: nota >= passing_score queda como aprobado';

    BEGIN TRY
        EXEC dbo.sp_RegisterExamAttempt @enr, @student, 95.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Examen: rechaza intentos despues de aprobar', 'ya aprobo', @err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_exam_nota_invalida
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @student INT = (SELECT id FROM users WHERE email = 'student.test@edugt.com');
    DECLARE @course INT, @enr INT, @att_id INT, @att_num INT, @passed BIT, @err VARCHAR(2048) = NULL;

    EXEC dbo.test_make_exam_fixture 'TEST ExamCert NotaInvalida', 'student.test@edugt.com', @course OUTPUT, @enr OUTPUT;

    BEGIN TRY
        EXEC dbo.sp_RegisterExamAttempt @enr, @student, 120.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Examen: rechaza nota fuera de 0-100', 'entre 0 y 100', @err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_exam_ajeno
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @student2 INT = (SELECT id FROM users WHERE email = 'student2.test@edugt.com');
    DECLARE @course INT, @enr INT, @att_id INT, @att_num INT, @passed BIT, @err VARCHAR(2048) = NULL;

    EXEC dbo.test_make_exam_fixture 'TEST ExamCert Ajeno', 'student.test@edugt.com', @course OUTPUT, @enr OUTPUT;

    BEGIN TRY
        EXEC dbo.sp_RegisterExamAttempt @enr, @student2, 90.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Examen: rechaza intento sobre inscripcion de otro estudiante', 'no pertenece', @err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_exam_reembolsada
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @student INT = (SELECT id FROM users WHERE email = 'student.test@edugt.com');
    DECLARE @course INT, @enr INT, @att_id INT, @att_num INT, @passed BIT, @err VARCHAR(2048) = NULL;

    EXEC dbo.test_make_exam_fixture 'TEST ExamCert Reembolsada', 'student.test@edugt.com', @course OUTPUT, @enr OUTPUT;
    UPDATE enrollments SET status = 'refunded' WHERE id = @enr;

    BEGIN TRY
        EXEC dbo.sp_RegisterExamAttempt @enr, @student, 90.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Examen: rechaza intento sobre inscripcion reembolsada', 'inscripcion activa', @err;
END;

-- sp_IssueCertificate (emision automatica al aprobar con el curso completo)

CREATE OR ALTER PROCEDURE dbo.test_case_cert_valido
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @student INT = (SELECT id FROM users WHERE email = 'student.test@edugt.com');
    DECLARE @course INT, @enr INT, @att_id INT, @att_num INT, @passed BIT, @err VARCHAR(2048) = NULL;
    DECLARE @cert_code VARCHAR(30);

    EXEC dbo.test_make_exam_fixture 'TEST ExamCert Valido', 'student.test@edugt.com', @course OUTPUT, @enr OUTPUT;
    -- 3 lecciones x 30 min; las dos con duracion suman 60 min reales contra 60 esperados.
    EXEC dbo.test_complete_course @enr, 30;

    BEGIN TRY
        EXEC dbo.sp_RegisterExamAttempt @enr, @student, 80.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT,
            @certificate_code = @cert_code OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH

    IF @err IS NULL AND EXISTS (SELECT 1 FROM certificates WHERE enrollment_id = @enr AND code = @cert_code AND status = 'valid')
        EXEC dbo.test_pass 'Certificado: al aprobar con el curso completo se emite automaticamente como valid';
    ELSE
        EXEC dbo.test_fail 'Certificado: al aprobar con el curso completo se emite automaticamente como valid', @detail=@err;

    IF @cert_code LIKE CONCAT('CERT-EDU-', YEAR(GETDATE()), '-[0-9][0-9][0-9][0-9][0-9]%')
        EXEC dbo.test_pass 'Certificado: codigo con formato CERT-EDU-YYYY-NNNNN';
    ELSE
        EXEC dbo.test_fail 'Certificado: codigo con formato CERT-EDU-YYYY-NNNNN', @detail=@cert_code;

    IF EXISTS (SELECT 1 FROM enrollments WHERE id = @enr AND status = 'completed' AND completed_at IS NOT NULL)
        EXEC dbo.test_pass 'Certificado: la inscripcion queda completed con completed_at';
    ELSE
        EXEC dbo.test_fail 'Certificado: la inscripcion queda completed con completed_at';

    IF EXISTS (SELECT 1 FROM notifications WHERE user_id = @student AND type = 'certificate' AND body LIKE '%' + @cert_code + '%')
        EXEC dbo.test_pass 'Certificado: se notifica al estudiante con el codigo';
    ELSE
        EXEC dbo.test_fail 'Certificado: se notifica al estudiante con el codigo';
END;

CREATE OR ALTER PROCEDURE dbo.test_case_cert_fraude
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @student INT = (SELECT id FROM users WHERE email = 'student.test@edugt.com');
    DECLARE @course INT, @enr INT, @att_id INT, @att_num INT, @passed BIT, @err VARCHAR(2048) = NULL;
    DECLARE @cert_code VARCHAR(30);

    EXEC dbo.test_make_exam_fixture 'TEST ExamCert Fraude', 'student.test@edugt.com', @course OUTPUT, @enr OUTPUT;
    -- 1 min por leccion: 2 min reales contra 60 esperados, muy por debajo del 50%.
    EXEC dbo.test_complete_course @enr, 1;

    BEGIN TRY
        EXEC dbo.sp_RegisterExamAttempt @enr, @student, 100.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT,
            @certificate_code = @cert_code OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH

    IF @err IS NULL AND EXISTS (
        SELECT 1 FROM certificates
        WHERE code = @cert_code AND status = 'pending_review' AND review_reason LIKE 'Tiempo de estudio implausible%'
    )
        EXEC dbo.test_pass 'Certificado: tiempo implausible queda pending_review con motivo';
    ELSE
        EXEC dbo.test_fail 'Certificado: tiempo implausible queda pending_review con motivo', @detail=@err;

    IF EXISTS (
        SELECT 1 FROM notifications n JOIN users u ON u.id = n.user_id
        WHERE u.role = 'academic' AND n.type = 'certificate' AND n.subject LIKE '%' + @cert_code + '%'
    )
        EXEC dbo.test_pass 'Certificado: el caso sospechoso se notifica al comite academico';
    ELSE
        EXEC dbo.test_fail 'Certificado: el caso sospechoso se notifica al comite academico';
END;

CREATE OR ALTER PROCEDURE dbo.test_case_cert_sin_aprobar
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @student INT = (SELECT id FROM users WHERE email = 'student.test@edugt.com');
    DECLARE @course INT, @enr INT, @att_id INT, @att_num INT, @passed BIT, @err VARCHAR(2048) = NULL;
    DECLARE @cert_id INT, @cert_code VARCHAR(30), @cert_status VARCHAR(20);

    EXEC dbo.test_make_exam_fixture 'TEST ExamCert SinAprobar', 'student.test@edugt.com', @course OUTPUT, @enr OUTPUT;
    EXEC dbo.test_complete_course @enr, 30;
    EXEC dbo.sp_RegisterExamAttempt @enr, @student, 50.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT;

    IF NOT EXISTS (SELECT 1 FROM certificates WHERE enrollment_id = @enr)
        EXEC dbo.test_pass 'Certificado: reprobar el examen no emite certificado';
    ELSE
        EXEC dbo.test_fail 'Certificado: reprobar el examen no emite certificado';

    BEGIN TRY
        EXEC dbo.sp_IssueCertificate @enr, @student, @cert_id OUTPUT, @cert_code OUTPUT, @cert_status OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Certificado: emision manual rechaza si no aprobo el examen', 'no ha aprobado el examen', @err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_cert_modulos_incompletos
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @student INT = (SELECT id FROM users WHERE email = 'student.test@edugt.com');
    DECLARE @course INT, @enr INT, @att_id INT, @att_num INT, @passed BIT, @err VARCHAR(2048) = NULL;
    DECLARE @cert_id INT, @cert_code VARCHAR(30), @cert_status VARCHAR(20);

    EXEC dbo.test_make_exam_fixture 'TEST ExamCert Incompleto', 'student.test@edugt.com', @course OUTPUT, @enr OUTPUT;
    EXEC dbo.sp_RegisterExamAttempt @enr, @student, 90.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT,
        @certificate_code = @cert_code OUTPUT;

    IF @cert_code IS NULL AND NOT EXISTS (SELECT 1 FROM certificates WHERE enrollment_id = @enr)
        EXEC dbo.test_pass 'Certificado: aprobar sin completar los modulos no emite certificado';
    ELSE
        EXEC dbo.test_fail 'Certificado: aprobar sin completar los modulos no emite certificado';

    BEGIN TRY
        EXEC dbo.sp_IssueCertificate @enr, @student, @cert_id OUTPUT, @cert_code OUTPUT, @cert_status OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Certificado: emision manual rechaza si faltan modulos', 'todos los modulos', @err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_cert_sin_examen
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @student INT = (SELECT id FROM users WHERE email = 'student.test@edugt.com');
    DECLARE @course INT, @enr INT, @err VARCHAR(2048) = NULL;
    DECLARE @cert_id INT, @cert_code VARCHAR(30), @cert_status VARCHAR(20);

    -- Curso que no requiere evaluacion final.
    EXEC dbo.test_make_exam_fixture 'TEST ExamCert SinExamen', 'student.test@edugt.com', @course OUTPUT, @enr OUTPUT;
    DELETE FROM exams WHERE course_id = @course;
    EXEC dbo.test_complete_course @enr, 30;

    BEGIN TRY
        EXEC dbo.sp_IssueCertificate @enr, @student, @cert_id OUTPUT, @cert_code OUTPUT, @cert_status OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH

    IF @err IS NULL AND @cert_status = 'valid'
        EXEC dbo.test_pass 'Certificado: curso sin examen final se certifica solo con el 100% de modulos';
    ELSE
        EXEC dbo.test_fail 'Certificado: curso sin examen final se certifica solo con el 100% de modulos', @detail=@err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_cert_duplicado
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @student INT = (SELECT id FROM users WHERE email = 'student.test@edugt.com');
    DECLARE @course INT, @enr INT, @att_id INT, @att_num INT, @passed BIT, @err VARCHAR(2048) = NULL;
    DECLARE @cert_id INT, @cert_code VARCHAR(30), @cert_status VARCHAR(20);

    EXEC dbo.test_make_exam_fixture 'TEST ExamCert Duplicado', 'student.test@edugt.com', @course OUTPUT, @enr OUTPUT;
    EXEC dbo.test_complete_course @enr, 30;
    -- Emite automaticamente el certificado.
    EXEC dbo.sp_RegisterExamAttempt @enr, @student, 90.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT;

    BEGIN TRY
        EXEC dbo.sp_IssueCertificate @enr, @student, @cert_id OUTPUT, @cert_code OUTPUT, @cert_status OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    EXEC dbo.test_expect_error 'Certificado: rechaza una segunda emision para la misma inscripcion', 'Ya se emitio', @err;
END;

CREATE OR ALTER PROCEDURE dbo.test_case_cert_correlativo
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @student INT = (SELECT id FROM users WHERE email = 'student.test@edugt.com');
    DECLARE @student2 INT = (SELECT id FROM users WHERE email = 'student2.test@edugt.com');
    DECLARE @course INT, @enr1 INT, @enr2 INT, @att_id INT, @att_num INT, @passed BIT;
    DECLARE @code1 VARCHAR(30), @code2 VARCHAR(30);

    EXEC dbo.test_make_exam_fixture 'TEST ExamCert Correlativo A', 'student.test@edugt.com', @course OUTPUT, @enr1 OUTPUT;
    EXEC dbo.test_make_exam_fixture 'TEST ExamCert Correlativo B', 'student2.test@edugt.com', @course OUTPUT, @enr2 OUTPUT;
    EXEC dbo.test_complete_course @enr1, 30;
    EXEC dbo.test_complete_course @enr2, 30;
    EXEC dbo.sp_RegisterExamAttempt @enr1, @student,  90.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT, @code1 OUTPUT;
    EXEC dbo.sp_RegisterExamAttempt @enr2, @student2, 90.00, @att_id OUTPUT, @att_num OUTPUT, @passed OUTPUT, @code2 OUTPUT;

    DECLARE @n1 INT = CAST(SUBSTRING(@code1, LEN('CERT-EDU-YYYY-') + 1, 30) AS INT);
    DECLARE @n2 INT = CAST(SUBSTRING(@code2, LEN('CERT-EDU-YYYY-') + 1, 30) AS INT);
    DECLARE @detail VARCHAR(200) = CONCAT(@code1, ' -> ', @code2);

    IF @n2 = @n1 + 1
        EXEC dbo.test_pass 'Certificado: dos emisiones seguidas tienen correlativos consecutivos';
    ELSE
        EXEC dbo.test_fail 'Certificado: dos emisiones seguidas tienen correlativos consecutivos', @detail=@detail;
END;

-- EJECUTAR TODOS
PRINT 'PRUEBAS FUNCIONALES: EXAMEN FINAL Y CERTIFICADOS';

EXEC dbo.test_cleanup_courses 'TEST ExamCert%';
EXEC dbo.test_cleanup_test_wallets;
EXEC dbo.test_case_exam_crear;
EXEC dbo.test_case_exam_primer_intento;
EXEC dbo.test_case_exam_max_intentos;
EXEC dbo.test_case_exam_ya_aprobado;
EXEC dbo.test_case_exam_nota_invalida;
EXEC dbo.test_case_exam_ajeno;
EXEC dbo.test_case_exam_reembolsada;
EXEC dbo.test_case_cert_valido;
EXEC dbo.test_case_cert_fraude;
EXEC dbo.test_case_cert_sin_aprobar;
EXEC dbo.test_case_cert_modulos_incompletos;
EXEC dbo.test_case_cert_sin_examen;
EXEC dbo.test_case_cert_duplicado;
EXEC dbo.test_case_cert_correlativo;
EXEC dbo.test_cleanup_courses 'TEST ExamCert%';
EXEC dbo.test_cleanup_test_wallets;

PRINT '';
